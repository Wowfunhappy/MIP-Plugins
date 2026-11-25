//
//  ArchiveUtilityPlus.m
//  Archive Utility opens more archive formats (7z, RAR, xz, LZMA, Zstandard,
//  CAB, ARJ, ar, LHA/LZH), through the 7-Zip command-line tool in the
//  bundle's Resources (7zz, with MacPorts' legacy support library in
//  Frameworks), with a real progress bar; and those files get icons.
//
//  Extracting: Archive Utility asks -[BAHController isDearchivable:...] which
//  decompressor handles a file. For these formats it gets an
//  ArchiveUtilityPlus_Decompressor (a BAHDecompressor subclass made at load
//  time, as BAHDecompressor is Archive Utility's), whose
//  -_decompressPerformCopy runs 7zz. 7zz reports its progress (-bsp1) as
//  " NN%" updates, which feed Archive Utility's own determinate progress bar
//  (-[BAHCodec _updateProgressBar:], a percentage). Its output is read as it
//  comes, so a long listing can't fill the pipe and stall it.
//
//  Icons: the types are declared, with their icons, by
//  ArchiveUtilityPlusIcons.app in Resources (an app only so that
//  LaunchServices reads its declarations). LaunchServices finds apps by
//  itself only in some places, and of several copies of a declaration only
//  one is active - the first one it saw. A copy that came first (a download,
//  a disk image, a build folder, an old install) keeps the types even once it
//  is gone, and the installed one stays inactive. So the installed copy is
//  registered, and any other copy of it (same name or identifier) that holds
//  one of its types is unregistered, which makes the installed one active.
//  Other apps declaring these types are left alone. This is done in Finder
//  (MIP loads the bundle there too, for this alone), so it happens at every
//  login, and in Archive Utility.
//
//  MIP loads this while the app is checking in with LaunchServices, so
//  everything that calls LaunchServices waits until the app has finished
//  launching.
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreServices/CoreServices.h>
#import "ZKSwizzle.h"

extern OSStatus _LSUnregisterURL(CFURLRef url);    // LaunchServices (private; what lsregister -u does)

static NSString *const kIconsAppName = @"ArchiveUtilityPlusIcons.app";
static NSString *const kIconsAppIdentifier = @"Wowfunhappy.ArchiveUtilityPlusIcons";

// Extension -> the type declared for it (by ArchiveUtilityPlusIcons.app).
static NSDictionary *ArchiveUtilityPlusTypes(void)
{
    static NSDictionary *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = [@{
            @"7z": @"org.7-zip.7-zip-archive",
            @"rar": @"com.rarlab.rar-archive",
            @"xz": @"org.tukaani.xz-archive",
            @"txz": @"org.tukaani.xz-tar-archive",
            @"lzh": @"public.archive.lzh",
            @"lha": @"public.archive.lha",
            @"lzma": @"org.tukaani.lzma-archive",
            @"zst": @"org.facebook.zstandard-archive",
            @"tzst": @"org.facebook.zstandard-tar-archive",
            @"cab": @"com.microsoft.cab-archive",
            @"arj": @"public.archive.arj",
            @"ar": @"public.archive.ar",
        } retain];
    });
    return types;
}

@interface ArchiveUtilityPlus : NSObject
@end

#pragma mark - Extracting

static Ivar ArchiveUtilityPlusIvar(id object, const char *name)
{
    return class_getInstanceVariable(object_getClass(object), name);
}

static BOOL ArchiveUtilityPlusCanceled(id self)
{
    Ivar ivar = ArchiveUtilityPlusIvar(self, "_progressCanceled");
    return ivar && *(BOOL *)((char *)self + ivar_getOffset(ivar));
}

static void ArchiveUtilityPlusEnableProgress(id self, BOOL enable)
{
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(_enableProgressBar:), enable);
}

// Starts the bar over (it only moves forward otherwise), at 0.
static void ArchiveUtilityPlusResetProgress(id self)
{
    Ivar last = ArchiveUtilityPlusIvar(self, "_lastPercent");
    if (last) *(double *)((char *)self + ivar_getOffset(last)) = 0;
    [self performSelectorOnMainThread:@selector(updateProgressBar:) withObject:@0.0 waitUntilDone:NO];
}

// The last " NN%" in 7zz's progress output so far, or -1.
static double ArchiveUtilityPlusLastPercent(NSData *data)
{
    const char *bytes = [data bytes];
    for (NSInteger i = (NSInteger)[data length] - 1; i > 0; i--) {
        if (bytes[i] != '%') continue;
        NSInteger start = i;
        while (start > 0 && bytes[start - 1] >= '0' && bytes[start - 1] <= '9') start--;
        if (start == i) continue;
        return (double)strtol(bytes + start, NULL, 10);
    }
    return -1;
}

static BOOL ArchiveUtilityPlusExtract(id self, SEL _cmd)
{
    if (!((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(_decompressSetupTarget))) return NO;

    NSString *sourcePath = ((id (*)(id, SEL))objc_msgSend)(self, @selector(copySource));
    NSString *targetPath = ((id (*)(id, SEL))objc_msgSend)(self, @selector(copyTarget));
    NSString *finalDest = ((id (*)(id, SEL))objc_msgSend)(self, @selector(finalDestDirectory));

    Ivar determinate = ArchiveUtilityPlusIvar(self, "_allowDeterminateProgressBar");
    if (determinate) *(BOOL *)((char *)self + ivar_getOffset(determinate)) = YES;
    ArchiveUtilityPlusEnableProgress(self, YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(_enableProgressCancel:), YES);

    NSString *sevenZip = [[NSBundle bundleForClass:[ArchiveUtilityPlus class]] pathForResource:@"7zz" ofType:nil];
    NSString *password = nil;
    BOOL firstAttempt = YES;

    while (YES) {
        if (!firstAttempt) {
            NSMutableString *passwordString = [NSMutableString string];
            NSDictionary *passwordDict = @{ @"PWSheetFileNamePrompt": sourcePath, @"PWSheetReturnedPW": passwordString };
            [self performSelector:@selector(askForArchivePassword:) withObject:passwordDict];

            Ivar progressViewIvar = ArchiveUtilityPlusIvar(self, "_progressView");
            id progressView = progressViewIvar ? object_getIvar(self, progressViewIvar) : nil;
            if ([progressView respondsToSelector:@selector(userDidCancelPasswordSheet)] &&
                ((BOOL (*)(id, SEL))objc_msgSend)(progressView, @selector(userDidCancelPasswordSheet))) {
                ArchiveUtilityPlusEnableProgress(self, NO);
                return NO;
            }
            password = [NSString stringWithString:passwordString];
        }
        ArchiveUtilityPlusResetProgress(self);

        NSTask *task = [[[NSTask alloc] init] autorelease];
        [task setLaunchPath:sevenZip];
        [task setArguments:@[ @"x", @"-y", @"-bsp1", [@"-o" stringByAppendingString:targetPath],
                              [password length] ? [@"-p" stringByAppendingString:password] : @"-p",
                              sourcePath ]];
        NSPipe *outputPipe = [NSPipe pipe], *errorPipe = [NSPipe pipe];
        [task setStandardOutput:outputPipe];
        [task setStandardError:errorPipe];

        // Read as it comes, on their own queues.
        NSMutableData *output = [NSMutableData data], *errors = [NSMutableData data];
        [[outputPipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *handle) {
            NSData *chunk = [handle availableData];
            double percent;
            @synchronized (output) {
                [output appendData:chunk];
                percent = ArchiveUtilityPlusLastPercent(output);
            }
            if (percent >= 0) ((void (*)(id, SEL, double))objc_msgSend)(self, @selector(_updateProgressBar:), percent);
        }];
        [[errorPipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *handle) {
            NSData *chunk = [handle availableData];
            @synchronized (errors) { [errors appendData:chunk]; }
        }];

        [task launch];
        BOOL canceled = NO;
        while ([task isRunning]) {
            if (ArchiveUtilityPlusCanceled(self)) {
                [task terminate];
                canceled = YES;
                break;
            }
            [NSThread sleepForTimeInterval:0.1];
        }
        [task waitUntilExit];

        [[outputPipe fileHandleForReading] setReadabilityHandler:nil];
        [[errorPipe fileHandleForReading] setReadabilityHandler:nil];
        NSData *restOfOutput = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *restOfErrors = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *outputString, *errorString;
        @synchronized (output) {
            [output appendData:restOfOutput];
            outputString = [[[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] autorelease];
        }
        @synchronized (errors) {
            [errors appendData:restOfErrors];
            errorString = [[[NSString alloc] initWithData:errors encoding:NSUTF8StringEncoding] autorelease];
        }

        if (canceled) {
            ArchiveUtilityPlusEnableProgress(self, NO);
            return NO;
        }

        BOOL noFilesExtracted = [outputString rangeOfString:@"No files to process"].location != NSNotFound;
        BOOL isPasswordError = noFilesExtracted
            || [errorString rangeOfString:@"Wrong password"].location != NSNotFound
            || [errorString rangeOfString:@"Data Error in encrypted file"].location != NSNotFound
            || [errorString rangeOfString:@"Can not open encrypted archive"].location != NSNotFound;

        if ([task terminationStatus] != 0 || noFilesExtracted) {
            if (isPasswordError) {
                firstAttempt = NO;
                continue;
            }
            ArchiveUtilityPlusEnableProgress(self, NO);
            return NO;
        }
        break;
    }

    ((void (*)(id, SEL, double))objc_msgSend)(self, @selector(_updateProgressBar:), 100);
    ArchiveUtilityPlusEnableProgress(self, NO);

    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:targetPath error:nil];
    NSString *finalTargetPath = ([contents count] == 1)
        ? [finalDest stringByAppendingPathComponent:[contents objectAtIndex:0]]
        : [finalDest stringByAppendingPathComponent:[[sourcePath lastPathComponent] stringByDeletingPathExtension]];
    [self performSelector:@selector(setFinalTargetPath:) withObject:finalTargetPath];
    return YES;
}

static Class ArchiveUtilityPlusDecompressorClass(void)
{
    static Class decompressor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = objc_getClass("BAHDecompressor");
        if (!base) return;
        decompressor = objc_allocateClassPair(base, "ArchiveUtilityPlus_Decompressor", 0);
        if (!decompressor) return;
        Method method = class_getInstanceMethod(base, @selector(_decompressPerformCopy));
        class_addMethod(decompressor, @selector(_decompressPerformCopy), (IMP)ArchiveUtilityPlusExtract, method_getTypeEncoding(method));
        objc_registerClassPair(decompressor);
    });
    return decompressor;
}

static NSDictionary *ArchiveUtilityPlusPreferences(void)
{
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"dearchive-move-after", @"dearchive-into", @"dearchive-reveal-after",
                             @"openIfSingleItem", @"dearchive-move-intermediate-after", @"dearchive-recursively" ]) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)key, CFSTR("com.apple.archiveutility")));
        if (value) options[key] = value;
    }
    return options;
}

@interface ArchiveUtilityPlus_BAHController : NSObject
@end

@implementation ArchiveUtilityPlus_BAHController

- (BOOL)isDearchivable:(NSString *)path whichController:(id *)controller isPrimaryArchive:(BOOL)isPrimary
{
    NSString *extension = [[path pathExtension] lowercaseString];
    Class decompressor = ArchiveUtilityPlusDecompressorClass();
    if (controller && decompressor && ArchiveUtilityPlusTypes()[extension]) {
        *controller = ((id (*)(id, SEL, id, id))objc_msgSend)([decompressor alloc], @selector(initWithFile:andOptions:),
                                                              path, ArchiveUtilityPlusPreferences());
        return YES;
    }
    return ZKOrig(BOOL, path, controller, isPrimary);
}

@end

#pragma mark - Types and icons

// Archive Utility opens these types (and files with these extensions, if
// another app's type claims them).
static void ArchiveUtilityPlusSetDefaultHandler(void)
{
    NSDictionary *types = ArchiveUtilityPlusTypes();
    for (NSString *extension in types) {
        LSSetDefaultRoleHandlerForContentType((CFStringRef)types[extension], kLSRolesViewer | kLSRolesEditor,
                                              CFSTR("com.apple.archiveutility"));
        CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (CFStringRef)extension, kUTTypeData);
        if (uti) {
            LSSetDefaultRoleHandlerForContentType(uti, kLSRolesViewer | kLSRolesEditor, CFSTR("com.apple.archiveutility"));
            CFRelease(uti);
        }
    }
}

// Whether `url` is a copy of the icons app other than `ours` (by name: copies
// from before it had an identifier; or by identifier). It may no longer exist.
static BOOL ArchiveUtilityPlusIsOtherIconsApp(NSURL *url, NSURL *ours)
{
    if (!url || [[[url path] stringByStandardizingPath] isEqualToString:[[ours path] stringByStandardizingPath]]) return NO;
    if ([[url lastPathComponent] isEqualToString:kIconsAppName]) return YES;
    return [[[NSBundle bundleWithURL:url] bundleIdentifier] isEqualToString:kIconsAppIdentifier];
}

static void ArchiveUtilityPlusRegisterIcons(void)
{
    NSURL *ours = [[NSBundle bundleForClass:[ArchiveUtilityPlus class]] URLForResource:@"ArchiveUtilityPlusIcons" withExtension:@"app"];
    if (!ours) return;
    OSStatus status = LSRegisterURL((CFURLRef)ours, true);
    if (status != noErr) {
        NSLog(@"ArchiveUtilityPlus: registering %@ failed: %d", [ours path], (int)status);
        return;
    }

    // What decides each type: its declaration, and what its extension maps to
    // (an old copy may declare an extension under another identifier).
    NSDictionary *types = ArchiveUtilityPlusTypes();
    for (int round = 0; round < 32; round++) {
        NSMutableSet *utis = [NSMutableSet setWithArray:[types allValues]];
        for (NSString *extension in types) {
            NSString *uti = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (CFStringRef)extension, NULL));
            if (uti) [utis addObject:uti];
        }
        BOOL changed = NO;
        for (NSString *uti in utis) {
            NSURL *declarer = CFBridgingRelease(UTTypeCopyDeclaringBundleURL((CFStringRef)uti));
            if (!ArchiveUtilityPlusIsOtherIconsApp(declarer, ours)) continue;
            NSLog(@"ArchiveUtilityPlus: %@ was declared by another copy of the icons app, %@; unregistering it", uti, [declarer path]);
            _LSUnregisterURL((CFURLRef)declarer);
            changed = YES;
        }
        if (!changed) break;
    }
}

@implementation ArchiveUtilityPlus

+ (void)appDidFinishLaunching:(NSNotification *)note
{
    BOOL archiveUtility = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.archiveutility"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        ArchiveUtilityPlusRegisterIcons();
        if (archiveUtility) ArchiveUtilityPlusSetDefaultHandler();
    });
}

+ (void)load
{
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.archiveutility"]) {
        ZKSwizzle(ArchiveUtilityPlus_BAHController, BAHController);
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification object:nil];
}

@end
