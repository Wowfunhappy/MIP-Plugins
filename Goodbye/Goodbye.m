//
//  Goodbye.m
//  Apps quit once their last window is closed and you've moved on to
//  another app.
//
//  AppKit asks the app delegate -applicationShouldTerminateAfterLastWindowClosed:
//  as the last window closes. If the app says YES it quits then, as always.
//  Otherwise Goodbye answers NO and arms: the next time the app is inactive
//  with no windows, it quits (through -terminate:, so unsaved documents are
//  still asked about). Closing the last window of an app that is already in
//  the background quits it at once; in the frontmost app it waits until you
//  switch away, so you can still open a new window.
//
//  Deciding:
//  - The check runs a run loop turn after the app resigns active, once
//    AppKit has finished ordering windows out (panels that hide on
//    deactivation are gone by then; they don't keep an app open).
//  - It only quits if the app is still inactive then.
//  - Windows count if they are visible or minimized. A hidden app's windows
//    aren't visible, so for a hidden app, what counts is whether it had
//    windows as it was hidden. Without that, an armed app with a window
//    reopened since would quit when hidden (Cmd-H deactivates it).
//  - Finding windows again disarms it.
//
//  Not in apps listed in Info.plist's MIPExcludedBundleNames (MIP doesn't load
//  it there), in agent apps (LSUIElement), or in an app with the
//  GoodbyeBlacklist default set (defaults write <app> GoodbyeBlacklist -bool YES).
//
//  Loaded by MIP while the app is still launching, before it has a delegate,
//  so the delegate's class is hooked once the app has finished launching.
//

#import <Cocoa/Cocoa.h>
#import "ZKSwizzle.h"

static BOOL gArmed;
static BOOL gDelegateAnswers;           // the delegate implements the method itself
static BOOL gHadWindowsWhenHidden;

static BOOL GoodbyeHasWindows(void)
{
    for (NSWindow *window in [NSApp windows]) {
        if ([window isVisible] || [window isMiniaturized]) return YES;
    }
    return [NSApp isHidden] && gHadWindowsWhenHidden;
}

@interface Goodbye : NSObject
@end

@implementation Goodbye

+ (void)check
{
    if (!gArmed || [NSApp isActive]) return;
    if (GoodbyeHasWindows()) {
        gArmed = NO;
        return;
    }
    [NSApp terminate:nil];
}

+ (void)scheduleCheck
{
    [self performSelector:@selector(check) withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];
}

+ (void)appDidResignActive:(NSNotification *)note
{
    if (gArmed) [self scheduleCheck];
}

+ (void)appWillHide:(NSNotification *)note
{
    gHadWindowsWhenHidden = NO;
    gHadWindowsWhenHidden = GoodbyeHasWindows();
}

+ (void)appDidFinishLaunching:(NSNotification *)note
{
    Class delegateClass = [[NSApp delegate] class];
    if (!delegateClass) return;     // nothing to ask; AppKit keeps the app open
    gDelegateAnswers = [delegateClass instancesRespondToSelector:@selector(applicationShouldTerminateAfterLastWindowClosed:)];
    _ZKSwizzle(objc_getClass("Goodbye_AppDelegate"), delegateClass);

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(appDidResignActive:) name:NSApplicationDidResignActiveNotification object:NSApp];
    [center addObserver:self selector:@selector(appWillHide:) name:NSApplicationWillHideNotification object:NSApp];
}

+ (void)load
{
    NSBundle *app = [NSBundle mainBundle];
    if ([[app objectForInfoDictionaryKey:@"LSUIElement"] boolValue]) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GoodbyeBlacklist"]) return;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification object:nil];
}

@end

// Methods of the app delegate's class. Only this one: anything else here would
// be added to (or replace) the delegate's own methods.
@interface Goodbye_AppDelegate : NSObject
@end

@implementation Goodbye_AppDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    if (gDelegateAnswers && ZKOrig(BOOL, sender)) return YES;
    gArmed = YES;
    if (![NSApp isActive]) [Goodbye scheduleCheck];
    return NO;
}

@end
