//
//  GreenFullscreen.m
//  The green window button toggles full screen, as in OS X 10.10 and later,
//  in windows that can go full screen (and is disabled in the rest); the
//  full-screen button at the top right and the Zoom menu items go away; and
//  the button shows Yosemite's full-screen arrows where it showed a +.
//
//  Loaded by MIP while the app is still launching, before its menus exist:
//  Zoom items are taken out once it has finished launching, and again as
//  windows update, for apps that build their menus later or their own way
//  (Firefox). An item goes if its action is the standard one (-performZoom:,
//  -zoomAll:), whatever the app's language, or if it is titled Zoom or
//  Zoom All in an English Window menu.
//
//  The arrows: AppKit draws the title bar buttons with CoreUI's CUIDraw
//  (widget "titlebarzoom", state "rollover" or "pressed" showing the glyph).
//  The + is part of that art - whichever art it is: Mavericks', or Snow
//  Leopard's from SnowLeopardWindows - so for a zoom button that toggles full
//  screen, the button is drawn as usual but off screen, along with its
//  glyph-less "normal" state (and "rollover", to find the +):
//    - the + is where the rollover art differs from the normal art (they
//      differ only there);
//    - rollover without the + is the normal art; pressed without it is the
//      pressed art with the + filled in from the normal art, mapped the way
//      pressed darkens normal elsewhere (a per-channel linear fit);
//    - the arrows (Yosemite's, Resources/FullScreenEnterGlyph[@2x].png: how far each
//      pixel moves toward the glyph colour, extracted from OS X 10.10's
//      SystemAppearance.car) are scaled so that Yosemite's + would match this
//      +, centred where it was, and darken the button as the + did, channel by
//      channel. (Only the enter arrows: Mavericks shows no title bar buttons
//      in full screen.)
//  Results are cached by CUIDraw's options. CUIDraw is hooked once the app has
//  finished launching, so that it comes before any other plugin's hook that
//  draws the buttons itself (SnowLeopardWindows), whose art it then gets.
//  Only zoom buttons GreenFullscreen set up are changed: AppKit's cell marks
//  them while it draws (Carbon windows, which keep zooming, keep their +).
//
//  The menu bar's exit-full-screen button moves from the right end to the left
//  end, before the Apple menu. Mavericks' button on the right is a status item
//  AppKit makes for each full-screen space (-[_NSFullScreenTransition
//  makeExitFullScreenStatusItem]), which is no longer made. HIToolbox's menu
//  bar view (HIMenuBarView, one per display, drawn on that display's menu bar
//  in every space) has a button of its own at the left end, which nothing in
//  Mavericks turns on: with a flag set, the view moves its menus right to make
//  room (from 10 points to 42), draws the button (part 10000), and tracks it,
//  calling HIExitFullScreenMode when it is clicked. The flag is set while the
//  view's display shows one of the app's full-screen windows: checked whenever
//  the view lays itself out (HIMenuBarView::EnsureBarLayout, before it draws
//  or hit-tests), with the layout invalidated when the answer changes. Where
//  the flag is in the view is read from the code that tests it for part
//  10000 (HIMenuBarView::GetPartBoundsSelf), so no offset is assumed. The
//  button was left unfinished, so:
//    - it draws a zoom button: drawn instead (in the CUIDraw hook) is the art
//      AppKit's status item drew, in the same place from the top;
//    - the Apple logo doesn't move with the menus: the window server draws it,
//      on full-screen menu bars from a window HIToolbox draws once at 10
//      points from the left. That window is left empty and the view draws the
//      logo itself, in the Apple menu's place;
//    - a click asks NSApp to leave full screen on every display: it takes only
//      the clicked display's full-screen window out of full screen.
//  If anything is missing, the status item stays where it was.
//

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#import "ZKSwizzle.h"

typedef OSStatus (*GreenFullscreenCUIDrawFn)(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result);
static GreenFullscreenCUIDrawFn orig_CUIDraw;

static __thread BOOL gDrawingZoom;              // set while a full-screen zoom button draws

static CGImageRef gArrows[2];                   // [0 = 1x, 1 = 2x]: coverage masks (Gray)
static NSMutableDictionary *gArtCache;          // options + scale -> CGImage

#pragma mark - Zoom menu items

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

#pragma mark - The arrows

// Premultiplied BGRA pixels of the button as CUIDraw draws it with `options`
// (unflipped), `w` x `h` pixels at `scale`.
static NSMutableData *GreenFullscreenRender(CFTypeRef renderer, NSDictionary *options, size_t w, size_t h, CGFloat scale)
{
    NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate([pixels mutableBytes], w, h, 8, w * 4, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGContextScaleCTM(ctx, scale, scale);
    NSMutableDictionary *o = [[options mutableCopy] autorelease];
    o[@"is.flipped"] = @NO;
    orig_CUIDraw(renderer, CGRectMake(0, 0, w / scale, h / scale), ctx, (CFDictionaryRef)o, NULL);
    CGContextRelease(ctx);
    return pixels;
}

// `glyph` drawn into a w x h coverage mask (0-255), `size` pixels square,
// centred at (cx, cy) (pixels, from the bottom left).
static NSMutableData *GreenFullscreenGlyphMask(CGImageRef glyph, size_t w, size_t h, CGFloat size, CGFloat cx, CGFloat cy)
{
    NSMutableData *mask = [NSMutableData dataWithLength:w * h];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate([mask mutableBytes], w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(cx - size / 2, cy - size / 2, size, size), glyph);
    CGContextRelease(ctx);
    return mask;
}

static CGImageRef GreenFullscreenCopyArt(CFTypeRef renderer, NSDictionary *options, CGSize size, CGFloat scale)
{
    size_t w = (size_t)ceil(size.width * scale), h = (size_t)ceil(size.height * scale);
    if (w == 0 || h == 0 || w > 256 || h > 256) return nil;
    BOOL pressed = [options[@"state"] isEqualToString:@"pressed"];

    NSMutableDictionary *o = [[options mutableCopy] autorelease];
    NSMutableData *shownData = GreenFullscreenRender(renderer, options, w, h, scale);
    o[@"state"] = @"normal";
    NSMutableData *normalData = GreenFullscreenRender(renderer, o, w, h, scale);
    o[@"state"] = @"rollover";
    NSMutableData *rolloverData = pressed ? GreenFullscreenRender(renderer, o, w, h, scale) : shownData;
    if (!shownData || !normalData || !rolloverData) return nil;
    uint8_t *shown = [shownData mutableBytes];
    const uint8_t *normal = [normalData bytes], *rollover = [rolloverData bytes];

    // The +: where rollover differs from normal. Its strongest pixel, and its extent.
    size_t n = w * h, core = 0;
    int coreDiff = 0, minX = (int)w, maxX = -1, minY = (int)h, maxY = -1;
    NSMutableData *inGlyphData = [NSMutableData dataWithLength:n];
    uint8_t *inGlyph = [inGlyphData mutableBytes];
    for (size_t i = 0; i < n; i++) {
        int d = abs(normal[4 * i] - rollover[4 * i]) + abs(normal[4 * i + 1] - rollover[4 * i + 1]) + abs(normal[4 * i + 2] - rollover[4 * i + 2]);
        if (d <= 6) continue;
        inGlyph[i] = 1;
        if (d > coreDiff) { coreDiff = d; core = i; }
        if (d > 60) {
            int x = (int)(i % w), y = (int)(i / w);
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
    if (maxX < minX) return nil;                // no glyph to replace

    // The button without it.
    NSMutableData *bodyData = [NSMutableData dataWithData:pressed ? shownData : normalData];
    uint8_t *body = [bodyData mutableBytes];
    if (pressed) {
        for (int c = 0; c < 3; c++) {
            double sx = 0, sy = 0, sxx = 0, sxy = 0, count = 0;
            for (size_t i = 0; i < n; i++) {
                if (inGlyph[i] || normal[4 * i + 3] < 255) continue;
                double x = normal[4 * i + c], y = shown[4 * i + c];
                sx += x; sy += y; sxx += x * x; sxy += x * y; count++;
            }
            double denominator = count * sxx - sx * sx;
            double a = denominator > 0 ? (count * sxy - sx * sy) / denominator : 1, b = count > 0 ? (sy - a * sx) / count : 0;
            for (size_t i = 0; i < n; i++) {
                if (!inGlyph[i]) continue;
                double v = a * normal[4 * i + c] + b;
                body[4 * i + c] = (uint8_t)MAX(0, MIN(body[4 * i + 3], round(v)));
            }
        }
    }

    // How the + darkened the button, per channel, at its strongest pixel.
    double ratio[3];
    for (int c = 0; c < 3; c++) ratio[c] = body[4 * core + c] ? MIN(1.0, (double)shown[4 * core + c] / body[4 * core + c]) : 0;

    // The arrows, scaled as Yosemite's + (8 points square) would be to this one.
    CGFloat plusSize = MAX(maxX - minX, maxY - minY) + 1;
    CGFloat glyphScale = plusSize / 8.0;
    CGImageRef glyph = gArrows[plusSize > 10 ? 1 : 0];
    if (!glyph) return nil;
    CGFloat glyphSize = 16 * glyphScale;
    // Pixel rows run top to bottom in memory; CoreGraphics' y runs bottom to top.
    CGFloat cx = (minX + maxX + 1) / 2.0, cy = h - (minY + maxY + 1) / 2.0;
    NSMutableData *maskData = GreenFullscreenGlyphMask(glyph, w, h, glyphSize, cx, cy);
    if (!maskData) return nil;
    const uint8_t *mask = [maskData bytes];
    for (size_t i = 0; i < n; i++) {
        double m = mask[i] / 255.0;
        for (int c = 0; c < 3; c++) body[4 * i + c] = (uint8_t)round(body[4 * i + c] * (1 - m * (1 - ratio[c])));
    }

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)bodyData);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}

static __thread BOOL gDrawingMenuBar;           // set while an HIMenuBarView draws (see below)

// The menu bar's exit button (see below) is drawn as a title bar widget (a zoom
// button). In its place goes what AppKit's status item drew: CoreUI's
// TitlebarExitFullScreenTemplate, on, on a raised menu bar background (as
// NSStatusBarButtonCell draws it), centred on the widget and the same height
// from the top of the menu bar as the status item's.
static OSStatus GreenFullscreenDrawExitButton(CFTypeRef renderer, CGRect rect, CGContextRef ctx, NSDictionary *o, CFDictionaryRef *result)
{
    if ([o[@"kCUIMaskOnlyKey"] boolValue]) return noErr;
    NSDictionary *art = @{
        @"widget": @"image",
        @"imageNameKey": @"image.TitlebarExitFullScreenTemplate",
        @"imageIsGrayscaleKey": @YES,
        @"value": @YES,
        @"state": [o[@"state"] isEqual:@"pressed"] ? @"pressed" : @"normal",
        @"backgroundTypeKey": @"kCUIBackgroundTypeMenuBarRaised",
        @"kCUIUserInterfaceLayoutDirectionKey": @"kCUIUserInterfaceLayoutDirectionLeftToRight",
    };
    CGRect artRect = CGRectMake(floor(CGRectGetMidX(rect) - 14.5), floor(CGRectGetMidY(rect) - 11.5), 29, 23);
    return orig_CUIDraw(renderer, artRect, ctx, (CFDictionaryRef)art, result);
}

static OSStatus GreenFullscreen_CUIDraw(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result)
{
    NSDictionary *o = (NSDictionary *)options;
    if (gDrawingMenuBar && ctx && [o isKindOfClass:[NSDictionary class]] && [o[@"widget"] isEqual:@"titlebarzoom"])
        return GreenFullscreenDrawExitButton(renderer, rect, ctx, o, result);
    if (!gDrawingZoom || !ctx || ![o isKindOfClass:[NSDictionary class]] || ![o[@"widget"] isEqual:@"titlebarzoom"]
        || !([o[@"state"] isEqual:@"rollover"] || [o[@"state"] isEqual:@"pressed"]) || [o[@"kCUIMaskOnlyKey"] boolValue])
        return orig_CUIDraw(renderer, rect, ctx, options, result);

    CGFloat scale = CGContextGetUserSpaceToDeviceSpaceTransform(ctx).a;
    scale = scale >= 1.5 ? 2 : 1;
    NSMutableDictionary *key = [[o mutableCopy] autorelease];
    key[@"GreenFullscreen.scale"] = @(scale);
    key[@"GreenFullscreen.size"] = [NSValue valueWithSize:NSSizeFromCGSize(rect.size)];
    key[@"GreenFullscreen.tint"] = @([NSColor currentControlTint]);
    CGImageRef image;
    @synchronized (gArtCache) {
        image = (CGImageRef)gArtCache[key];
        if (!image) {
            image = GreenFullscreenCopyArt(renderer, o, rect.size, scale);
            if (!image) return orig_CUIDraw(renderer, rect, ctx, options, result);
            if ([gArtCache count] > 64) [gArtCache removeAllObjects];
            gArtCache[key] = (id)image;
            CGImageRelease(image);              // the cache keeps it
        }
        CGImageRetain(image);
    }
    CGContextSaveGState(ctx);
    if ([o[@"is.flipped"] boolValue]) {
        CGContextTranslateCTM(ctx, 0, CGRectGetMaxY(rect) + CGRectGetMinY(rect));
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextDrawImage(ctx, rect, image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
    return noErr;
}

#pragma mark - The menu bar's exit button

// Exported by HIToolbox and CoreGraphics in 64-bit too, though only declared for 32-bit or not at all.
extern OSStatus HIWindowGetBounds(WindowRef window, WindowRegionCode region, HICoordinateSpace space, HIRect *bounds);
extern void DrawMenuBar(void);
extern int CGSMainConnectionID(void);
extern CGContextRef CGWindowContextCreate(int cid, uint32_t wid, CFDictionaryRef options);

typedef void (*GreenFullscreenVoidFn)(void);
typedef void (*GreenFullscreenViewFn)(void *view);
typedef WindowRef (*GreenFullscreenGetWindowRefFn)(void *view);
typedef void (*GreenFullscreenGetTitleBoundsFn)(void *view, int index, CGRect *bounds);
typedef void (*GreenFullscreenDrawOnceFn)(void *view, CGRect bar, CGRect dirty, bool c, bool opaque, bool e, bool f, CGContextRef ctx);
typedef OSStatus (*GreenFullscreenDrawAppleMenuTitleFn)(const CGRect *bar, const CGRect *title, int state, int flags, void *a, void *b, CGContextRef ctx, int orientation);
typedef CFDictionaryRef (*GreenFullscreenCopyGlobalSettingsFn)(void *unused);

static GreenFullscreenViewFn orig_EnsureBarLayout;
static GreenFullscreenDrawOnceFn orig_DrawOnce;
static GreenFullscreenDrawAppleMenuTitleFn orig_HIThemeDrawAppleMenuTitle;
static GreenFullscreenCopyGlobalSettingsFn orig_CopyGlobalSettings;
static GreenFullscreenVoidFn orig_HIExitFullScreenMode;
static GreenFullscreenVoidFn GreenFullscreenInvalMenuBarLayout;
static GreenFullscreenGetWindowRefFn GreenFullscreenHIViewGetWindowRef;
static GreenFullscreenGetTitleBoundsFn GreenFullscreenGetTitleBounds;
static uint32_t *gFullScreenAppleWindow;        // HIToolbox's window for the logo on full-screen menu bars
static long gExitButtonFlag = -1;               // offset in HIMenuBarView of the byte whose bit 0 shows the button
static BOOL gExitButtonOnLeft;
static __thread BOOL gDrewAppleMenuTitle, gDrawingAppleWindow;

static BOOL GreenFullscreenShowsExitButton(void *view)
{
    return (((uint8_t *)view)[gExitButtonFlag] & 1) != 0;
}

// Where HIMenuBarView::GetPartBoundsSelf(part, rect) tests the flag for the
// button: `cmpw $10000, part`, a jne, then `testb $1, disp32(this)`
// (x86_64: f6 87 disp32 01; i386: f6 86 disp32 01). -1 if it isn't there.
static long GreenFullscreenFindExitButtonFlag(const uint8_t *code)
{
    for (int i = 0; i < 64; i++) {
        if (code[i] != 0x10 || code[i + 1] != 0x27) continue;
        for (int j = i + 2; j < i + 12; j++) {
            uint8_t modrm = code[j + 1];
            if (code[j] == 0xf6 && (modrm & 0xf8) == 0x80 && (modrm & 7) != 4 && code[j + 6] == 0x01) {
                int32_t offset;
                memcpy(&offset, code + j + 2, sizeof offset);
                return offset > 0 && offset < 0x1000 ? offset : -1;
            }
        }
        return -1;
    }
    return -1;
}

static CGDirectDisplayID GreenFullscreenDisplayID(NSScreen *screen)
{
    return [[[screen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
}

// The app's full-screen window shown on `displayID` (in its current space), if any.
static NSWindow *GreenFullscreenWindowOnDisplay(CGDirectDisplayID displayID)
{
    for (NSWindow *window in [NSApp windows]) {
        if (([window styleMask] & NSFullScreenWindowMask) && [window isVisible] && [window isOnActiveSpace]
            && GreenFullscreenDisplayID([window screen]) == displayID) return window;
    }
    return nil;
}

// Before the view lays itself out (and so before it draws or hit-tests): the
// button is shown while its display shows a full-screen window of the app's.
static void GreenFullscreen_EnsureBarLayout(void *view)
{
    BOOL show = NO;
    WindowRef menuBarWindow = GreenFullscreenHIViewGetWindowRef(view);
    HIRect bounds;
    if (menuBarWindow && HIWindowGetBounds(menuBarWindow, kWindowStructureRgn, kHICoordSpace72DPIGlobal, &bounds) == noErr) {
        CGDirectDisplayID displayID;
        uint32_t count = 0;
        if (CGGetDisplaysWithPoint(CGPointMake(CGRectGetMidX(bounds), CGRectGetMinY(bounds)), 1, &displayID, &count) == kCGErrorSuccess && count)
            show = GreenFullscreenWindowOnDisplay(displayID) != nil;
    }
    uint8_t *flag = (uint8_t *)view + gExitButtonFlag;
    if (((*flag & 1) != 0) != show) {
        *flag = (*flag & ~1) | show;
        GreenFullscreenInvalMenuBarLayout();
    }
    orig_EnsureBarLayout(view);
}

// The Apple menu's title (its logo). The view draws it only while the menu is
// open, or when it draws the menu bar opaque; otherwise the window server draws
// it - on full-screen menu bars from a window of the app's, 10 points from the
// left, where the menus begin without the button. That window is left empty
// (below), and the view draws the logo where the button has moved it.
static OSStatus GreenFullscreen_HIThemeDrawAppleMenuTitle(const CGRect *bar, const CGRect *title, int state, int flags, void *a, void *b, CGContextRef ctx, int orientation)
{
    if (gDrawingAppleWindow) return noErr;
    gDrewAppleMenuTitle = YES;
    return orig_HIThemeDrawAppleMenuTitle(bar, title, state, flags, a, b, ctx, orientation);
}

// MenuBarInstance::CopyGlobalSettings: makes (once) and draws the full-screen
// menu bars' Apple window.
static CFDictionaryRef GreenFullscreen_CopyGlobalSettings(void *unused)
{
    BOOL outer = gDrawingAppleWindow;
    gDrawingAppleWindow = YES;
    CFDictionaryRef settings = orig_CopyGlobalSettings(unused);
    gDrawingAppleWindow = outer;
    return settings;
}

static void GreenFullscreen_DrawOnce(void *view, CGRect bar, CGRect dirty, bool c, bool opaque, bool e, bool f, CGContextRef ctx)
{
    BOOL outerDrawing = gDrawingMenuBar, outerDrew = gDrewAppleMenuTitle;
    gDrawingMenuBar = YES;
    gDrewAppleMenuTitle = NO;
    orig_DrawOnce(view, bar, dirty, c, opaque, e, f, ctx);
    if (GreenFullscreenShowsExitButton(view) && !gDrewAppleMenuTitle) {
        CGRect title = CGRectNull;
        GreenFullscreenGetTitleBounds(view, 0, &title);     // the Apple menu comes first
        if (!CGRectIsEmpty(title) && CGRectIntersectsRect(title, dirty))
            orig_HIThemeDrawAppleMenuTitle(&bar, &title, 0, f, NULL, NULL, ctx, kHIThemeOrientationNormal);
    }
    gDrawingMenuBar = outerDrawing;
    gDrewAppleMenuTitle = outerDrew;
}

// Leaving full screen: the full-screen window on the display that was clicked
// (HIToolbox would ask NSApp to leave full screen on every display).
static void GreenFullscreen_HIExitFullScreenMode(void)
{
    NSPoint mouse = [NSEvent mouseLocation];
    for (NSScreen *screen in [NSScreen screens]) {
        if (!NSMouseInRect(mouse, [screen frame], NO)) continue;
        NSWindow *window = GreenFullscreenWindowOnDisplay(GreenFullscreenDisplayID(screen));
        if (window) {
            [window toggleFullScreen:nil];
            return;
        }
    }
    orig_HIExitFullScreenMode();
}

// The menu bar redraws when the app comes to or goes from a full-screen space,
// but not always when that space's window leaves full screen or the screens
// change: lay it out and draw it again then.
static void GreenFullscreenUpdateMenuBar(void)
{
    GreenFullscreenInvalMenuBarLayout();
    DrawMenuBar();
}

static BOOL GreenFullscreenMoveExitButton(void)
{
    typedef void (*HookFn)(void *symbol, void *replacement, void **original);
    typedef const void *(*GetImageFn)(const char *path);
    typedef void *(*FindSymbolFn)(const void *image, const char *name);
    HookFn hookFunction = (HookFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    GetImageFn getImage = (GetImageFn)dlsym(RTLD_DEFAULT, "MSGetImageByName");
    FindSymbolFn find = (FindSymbolFn)dlsym(RTLD_DEFAULT, "MSFindSymbol");
    const void *hitoolbox = getImage ? getImage("/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox") : NULL;
    if (!hookFunction || !find || !hitoolbox) {
        NSLog(@"GreenFullscreen: the exit full screen button stays on the right (no MSHookFunction, MSFindSymbol or HIToolbox).");
        return NO;
    }
    void *ensureBarLayout = find(hitoolbox, "__ZN13HIMenuBarView15EnsureBarLayoutEv");
    void *drawOnce = find(hitoolbox, "__ZN13HIMenuBarView8DrawOnceE6CGRectS0_bbbbP9CGContext");
    const uint8_t *getPartBounds = find(hitoolbox, "__ZN13HIMenuBarView17GetPartBoundsSelfEsP6CGRect");
    void *drawAppleMenuTitle = find(hitoolbox, "__HIThemeDrawAppleMenuTitle");
    void *copyGlobalSettings = find(hitoolbox, "__ZN15MenuBarInstance18CopyGlobalSettingsEv");
    void *exitFullScreenMode = find(hitoolbox, "_HIExitFullScreenMode");
#if __LP64__
    gFullScreenAppleWindow = find(hitoolbox, "__ZZL36GetFullScreenMenuBarAuxiliaryWindowsPjS_dE12sAppleWindow");
#else
    gFullScreenAppleWindow = find(hitoolbox, "__ZZL36GetFullScreenMenuBarAuxiliaryWindowsPjS_fE12sAppleWindow");
#endif
    GreenFullscreenInvalMenuBarLayout = (GreenFullscreenVoidFn)find(hitoolbox, "_InvalMenuBarLayout");
    GreenFullscreenHIViewGetWindowRef = (GreenFullscreenGetWindowRefFn)find(hitoolbox, "__ZN6HIView12GetWindowRefEv");
    GreenFullscreenGetTitleBounds = (GreenFullscreenGetTitleBoundsFn)find(hitoolbox, "__ZN13HIMenuBarView14GetTitleBoundsEiP6CGRect");
    gExitButtonFlag = getPartBounds ? GreenFullscreenFindExitButtonFlag(getPartBounds) : -1;
    Class transition = ZKClass(_NSFullScreenTransition);
    if (!ensureBarLayout || !drawOnce || gExitButtonFlag < 0 || !drawAppleMenuTitle || !copyGlobalSettings || !exitFullScreenMode || !gFullScreenAppleWindow
        || !GreenFullscreenInvalMenuBarLayout || !GreenFullscreenHIViewGetWindowRef || !GreenFullscreenGetTitleBounds
        || !transition || !class_getInstanceMethod(transition, @selector(makeExitFullScreenStatusItem))) {
        NSLog(@"GreenFullscreen: the exit full screen button stays on the right (HIToolbox's menu bar or AppKit's full-screen status item is not as expected).");
        return NO;
    }
    hookFunction(ensureBarLayout, (void *)GreenFullscreen_EnsureBarLayout, (void **)&orig_EnsureBarLayout);
    hookFunction(drawOnce, (void *)GreenFullscreen_DrawOnce, (void **)&orig_DrawOnce);
    hookFunction(drawAppleMenuTitle, (void *)GreenFullscreen_HIThemeDrawAppleMenuTitle, (void **)&orig_HIThemeDrawAppleMenuTitle);
    hookFunction(copyGlobalSettings, (void *)GreenFullscreen_CopyGlobalSettings, (void **)&orig_CopyGlobalSettings);
    hookFunction(exitFullScreenMode, (void *)GreenFullscreen_HIExitFullScreenMode, (void **)&orig_HIExitFullScreenMode);
    gExitButtonOnLeft = YES;

    // The Apple window was most likely made and drawn as the app launched.
    if (*gFullScreenAppleWindow) {
        CGContextRef ctx = CGWindowContextCreate(CGSMainConnectionID(), *gFullScreenAppleWindow, NULL);
        if (ctx) {
            CGContextClearRect(ctx, CGRectMake(0, 0, 10000, 10000));
            CGContextFlush(ctx);
            CGContextRelease(ctx);
        }
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification, NSApplicationDidChangeScreenParametersNotification])
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { GreenFullscreenUpdateMenuBar(); }];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil
                                                                usingBlock:^(NSNotification *note) { GreenFullscreenUpdateMenuBar(); }];
    return YES;
}

@interface GreenFullscreen__NSFullScreenTransition : NSObject
@end

@implementation GreenFullscreen__NSFullScreenTransition

- (void)makeExitFullScreenStatusItem
{
    if (!gExitButtonOnLeft) ZKOrig(void);
}

@end

#pragma mark - Hooks

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

// AppKit's title bar button cell (_NSThemeWidgetCell): marks the drawing of a
// zoom button that toggles full screen - drawn, or (a layer-backed button)
// its layer updated.
static BOOL GreenFullscreenIsOurZoomButton(NSView *view)
{
    NSWindow *window = [view window];
    return window && view == [window standardWindowButton:NSWindowZoomButton] && [(NSButton *)view action] == @selector(toggleFullScreen:);
}

@interface GreenFullscreen_NSThemeWidgetCell : NSButtonCell
@end

@implementation GreenFullscreen_NSThemeWidgetCell

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL outer = gDrawingZoom;
    gDrawingZoom = GreenFullscreenIsOurZoomButton(view);
    ZKOrig(void, frame, view);
    gDrawingZoom = outer;
}

- (void)updateLayerWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL outer = gDrawingZoom;
    gDrawingZoom = GreenFullscreenIsOurZoomButton(view);
    ZKOrig(void, frame, view);
    gDrawingZoom = outer;
}

@end

@interface GreenFullscreen : NSObject
@end

@implementation GreenFullscreen

+ (void)appDidFinishLaunching:(NSNotification *)note
{
    GreenFullscreenRemoveAllZoomItems();

    // After every bundle's +load, so this hook comes first (see the top).
    typedef void (*HookFn)(void *symbol, void *replacement, void **original);
    HookFn hookFunction = (HookFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    void *cuiDraw = dlsym(RTLD_DEFAULT, "CUIDraw");
    if (!hookFunction || !cuiDraw) {
        NSLog(@"GreenFullscreen: the zoom button keeps its + and the exit full screen button stays on the right (no MSHookFunction or CUIDraw).");
        return;
    }
    NSBundle *bundle = [NSBundle bundleForClass:self];
    for (int x2 = 0; x2 < 2; x2++) {
        NSURL *url = [bundle URLForResource:x2 ? @"FullScreenEnterGlyph@2x" : @"FullScreenEnterGlyph" withExtension:@"png"];
        CGImageSourceRef source = url ? CGImageSourceCreateWithURL((CFURLRef)url, NULL) : NULL;
        if (!source) continue;
        gArrows[x2] = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
    }
    BOOL arrows = gArrows[0] && gArrows[1];
    if (!arrows) NSLog(@"GreenFullscreen: the zoom button keeps its + (the bundle's arrows are missing).");
    if (GreenFullscreenMoveExitButton()) ZKSwizzle(GreenFullscreen__NSFullScreenTransition, _NSFullScreenTransition);
    if (!arrows && !gExitButtonOnLeft) return;
    gArtCache = [[NSMutableDictionary alloc] init];
    hookFunction(cuiDraw, (void *)GreenFullscreen_CUIDraw, (void **)&orig_CUIDraw);
    if (arrows) ZKSwizzle(GreenFullscreen_NSThemeWidgetCell, _NSThemeWidgetCell);
}

+ (void)load
{
    ZKSwizzle(GreenFullscreen_NSWindow, NSWindow);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification object:nil];
}

@end
