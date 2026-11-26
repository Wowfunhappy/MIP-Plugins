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

#import <AppKit/AppKit.h>
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

static OSStatus GreenFullscreen_CUIDraw(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result)
{
    NSDictionary *o = (NSDictionary *)options;
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
    NSBundle *bundle = [NSBundle bundleForClass:self];
    for (int x2 = 0; x2 < 2; x2++) {
        NSURL *url = [bundle URLForResource:x2 ? @"FullScreenEnterGlyph@2x" : @"FullScreenEnterGlyph" withExtension:@"png"];
        CGImageSourceRef source = url ? CGImageSourceCreateWithURL((CFURLRef)url, NULL) : NULL;
        if (!source) continue;
        gArrows[x2] = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
    }
    if (!hookFunction || !cuiDraw || !gArrows[0] || !gArrows[1]) {
        NSLog(@"GreenFullscreen: the zoom button keeps its + (%@).", (!hookFunction || !cuiDraw) ? @"no MSHookFunction or CUIDraw" : @"the bundle's arrows are missing");
        return;
    }
    gArtCache = [[NSMutableDictionary alloc] init];
    hookFunction(cuiDraw, (void *)GreenFullscreen_CUIDraw, (void **)&orig_CUIDraw);
    ZKSwizzle(GreenFullscreen_NSThemeWidgetCell, _NSThemeWidgetCell);
}

+ (void)load
{
    ZKSwizzle(GreenFullscreen_NSWindow, NSWindow);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification object:nil];
}

@end
