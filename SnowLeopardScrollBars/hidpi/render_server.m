//
//  render_server.m
//  Build-time helper for build_hidpi.py: renders Snow Leopard CoreUI recipes
//  with Mavericks' ScalableUserInterface framework.
//
//  Usage: render_server <10.6 UI.bundle>, run with
//  DYLD_INSERT_LIBRARIES=render_cache.dylib (see render_cache.c).
//  Reads requests "<recipe.plist> <scale> <outprefix>" from stdin, one per
//  line. The recipe is a property list {properties = {...}}: one state of a
//  recipe with every property spelled out (Mavericks' renderer measures
//  subnodes as empty, so build_hidpi.py flattens them). Writes each part of
//  the rendering to <outprefix>_<n>.raw (premultiplied ARGB, rows top to
//  bottom, parts in row-major order) and answers "@@ok WxH WxH ..." or
//  "@@err". (The renderer prints its own warnings to stdout, hence the @@.)
//

#import <Cocoa/Cocoa.h>
#import <dlfcn.h>

typedef struct _QSIContext *QSIContextRef;
typedef struct _QSIElement *QSIElementRef;
typedef struct { long rows, columns; } QSIDimension;     // returned in registers
static QSIContextRef (*QSIOpenBundle)(CFURLRef);
static QSIElementRef (*QSICreateElement)(QSIContextRef, CFStringRef, int, int, float);
static QSIDimension (*QSIElementGetDimension)(QSIElementRef);
static CGImageRef (*QSIElementGetImage)(QSIElementRef, int, int);
static void (*QSIReleaseElement)(QSIElementRef);

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: render_server <UI.bundle>\n"); return 1; }
        NSString *ui = @(argv[1]);
        void *sui = dlopen("/System/Library/Frameworks/QuartzCore.framework/Versions/A/Frameworks/ScalableUserInterface.framework/Versions/A/ScalableUserInterface", RTLD_NOW);
        QSIOpenBundle = dlsym(sui, "QSIOpenBundle");
        QSICreateElement = dlsym(sui, "QSICreateElement");
        QSIElementGetDimension = dlsym(sui, "QSIElementGetDimension");
        QSIElementGetImage = dlsym(sui, "QSIElementGetImage");
        QSIReleaseElement = dlsym(sui, "QSIReleaseElement");
        void *(*artworkCache)(void) = dlsym(RTLD_DEFAULT, "CGSSharedArtworkCache");
        if (!QSIOpenBundle || !QSICreateElement || !QSIElementGetDimension || !QSIElementGetImage || !QSIReleaseElement) {
            fprintf(stderr, "render_server: ScalableUserInterface.framework not found (this needs OS X 10.9)\n");
            return 1;
        }
        if (!artworkCache || !artworkCache()) {
            fprintf(stderr, "render_server: run with DYLD_INSERT_LIBRARIES=render_cache.dylib\n");
            return 1;
        }

        // A scratch copy of the UI.bundle (its property lists and a link to
        // its resources) whose Recipes folder gets one file per request.
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingFormat:@"render_server.%d/UI.bundle", getpid()];
        NSString *contents = [tmp stringByAppendingPathComponent:@"Contents"];
        [fm createDirectoryAtPath:[contents stringByAppendingPathComponent:@"Recipes"] withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *f in @[@"Info.plist", @"id.plist", @"taxonomy.plist", @"version.plist"]) {
            NSString *src = [ui stringByAppendingFormat:@"/Contents/%@", f];
            if ([fm fileExistsAtPath:src]) [fm copyItemAtPath:src toPath:[contents stringByAppendingPathComponent:f] error:NULL];
        }
        [fm createSymbolicLinkAtPath:[contents stringByAppendingPathComponent:@"Resources"]
                 withDestinationPath:[ui stringByAppendingPathComponent:@"Contents/Resources"] error:NULL];

        char line[4096];
        int n = 0;
        while (fgets(line, sizeof line, stdin)) {
            @autoreleasepool {
                char path[2048], prefix[2048];
                float scale;
                if (sscanf(line, "%2047s %f %2047s", path, &scale, prefix) != 3) { printf("@@err\n"); fflush(stdout); continue; }
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@(path)];
                NSString *category = [NSString stringWithFormat:@"r%05d", n++];
                NSString *recipe = [contents stringByAppendingFormat:@"/Recipes/%@.xml", category];
                [[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL]
                    writeToFile:recipe atomically:NO];
                // A fresh context per request: the renderer caches elements per
                // context, keyed on only 16 bits of the path's hash. (Contexts
                // are not closed: QSICloseBundle crashes. This process is short-lived.)
                QSIContextRef context = QSIOpenBundle((CFURLRef)[NSURL fileURLWithPath:tmp]);
                QSIElementRef element = context ? QSICreateElement(context, (CFStringRef)category, 0, 0, scale) : NULL;
                [fm removeItemAtPath:recipe error:NULL];
                if (!element) { printf("@@err\n"); fflush(stdout); continue; }
                QSIDimension d = QSIElementGetDimension(element);
                NSMutableString *reply = [NSMutableString stringWithString:@"@@ok"];
                int k = 0;
                for (int r = 0; r < d.rows; r++) {
                    for (int c = 0; c < d.columns; c++, k++) {
                        CGImageRef image = QSIElementGetImage(element, r, c);
                        size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
                        NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
                        // The renderer's images are device RGB: draw them untransformed.
                        CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w * 4, CGImageGetColorSpace(image),
                                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
                        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
                        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
                        CGContextRelease(ctx);
                        [pixels writeToFile:[NSString stringWithFormat:@"%s_%d.raw", prefix, k] atomically:NO];
                        [reply appendFormat:@" %zux%zu", w, h];
                    }
                }
                QSIReleaseElement(element);
                printf("%s\n", reply.UTF8String);
                fflush(stdout);
            }
        }
        [fm removeItemAtPath:[tmp stringByDeletingLastPathComponent] error:NULL];
    }
    return 0;
}
