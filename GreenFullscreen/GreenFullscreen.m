//
//  GreenFullscreen.m
//  The green window button toggles full screen, as in OS X 10.10 and later,
//  in windows that can go full screen (and is disabled in the rest); the
//  full-screen button at the top right and the Zoom menu items go away.
//
//  Loaded by MIP while the app is still launching, before its menus exist:
//  Zoom items are taken out once it has finished launching, and again as
//  windows update, for apps that build their menus later or their own way
//  (Firefox). An item goes if its action is the standard one (-performZoom:,
//  -zoomAll:), whatever the app's language, or if it is titled Zoom or
//  Zoom All in an English Window menu.
//

#import <AppKit/AppKit.h>
#import "ZKSwizzle.h"

static BOOL GreenFullscreenIsZoomItem(NSMenuItem *item, BOOL inWindowMenu)
{
    SEL action = [item action];
    if (action == @selector(performZoom:) || action == @selector(zoomAll:)) return YES;
    return inWindowMenu && ([[item title] isEqualToString:@"Zoom"] || [[item title] isEqualToString:@"Zoom All"]);
}

static void GreenFullscreenRemoveZoomItems(NSMenu *menu, BOOL inWindowMenu)
{
    for (NSInteger i = [menu numberOfItems] - 1; i >= 0; i--) {
        if (GreenFullscreenIsZoomItem([menu itemAtIndex:i], inWindowMenu)) [menu removeItemAtIndex:i];
    }
}

static void GreenFullscreenRemoveAllZoomItems(void)
{
    NSMenu *windowsMenu = [NSApp windowsMenu];
    if (windowsMenu) GreenFullscreenRemoveZoomItems(windowsMenu, YES);
    for (NSMenuItem *top in [[NSApp mainMenu] itemArray]) {
        NSMenu *menu = [top submenu];
        if (menu && menu != windowsMenu) GreenFullscreenRemoveZoomItems(menu, [[top title] isEqualToString:@"Window"]);
    }
}

@interface GreenFullscreen_NSWindow : NSWindow
@end

@implementation GreenFullscreen_NSWindow

- (void)update
{
    ZKOrig(void);

    NSButton *zoomButton = [self standardWindowButton:NSWindowZoomButton];
    [zoomButton setAction:@selector(toggleFullScreen:)];

    ZKIMP origShowsFullScreenButton = ZKOriginalImplementation(self, @selector(showsFullScreenButton), __PRETTY_FUNCTION__);
    [zoomButton setEnabled:((BOOL (*)(id, SEL))origShowsFullScreenButton)(self, @selector(showsFullScreenButton))];

    GreenFullscreenRemoveAllZoomItems();
}

- (BOOL)showsFullScreenButton
{
    return NO;
}

@end

@interface GreenFullscreen : NSObject
@end

@implementation GreenFullscreen

+ (void)appDidFinishLaunching:(NSNotification *)note
{
    GreenFullscreenRemoveAllZoomItems();
}

+ (void)load
{
    ZKSwizzle(GreenFullscreen_NSWindow, NSWindow);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification object:nil];
}

@end
