//
//  SLWindows.m
//  SnowLeopardWindows' AppKit part (SnowLeopardWindows-AppKit), loaded by the
//  core (SLWindowsCore.m, which describes the plugin) into apps that have
//  AppKit: AppKit's title bar button layout and title text, textured
//  windows' background pattern, and apps' own button and tab images.
//

#import <Cocoa/Cocoa.h>
#import "SLWindowsShared.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- windows with their own appearance ---------------------------------------------------

// The CoreUI renderers of non-default NSAppearances (an app's own theme), as
// they are handed out, go to the core (gRegisterRenderer), whose CUIDraw hook
// passes their drawing through unchanged.
static SLRegisterRendererFn gRegisterRenderer;
static void *(*orig_coreUIRenderer)(id, SEL);

static BOOL SLIsDefaultAppearance(id appearance)
{
    SEL sel = sel_registerName("_isDefaultAppearance");
    return !appearance || ![appearance respondsToSelector:sel] || ((BOOL (*)(id, SEL))objc_msgSend)(appearance, sel);
}

static void *sl_coreUIRenderer(id self, SEL _cmd)
{
    void *renderer = orig_coreUIRenderer(self, _cmd);
    if (renderer && !SLIsDefaultAppearance(self)) gRegisterRenderer(renderer);
    return renderer;
}

// A window frame whose window has a non-default appearance of its own.
static BOOL SLFrameHasCustomAppearance(id frame)
{
    NSWindow *window = [frame window];
    return [window respondsToSelector:@selector(appearance)] && !SLIsDefaultAppearance([window appearance]);
}

static void SLHookAppearance(void)
{
    Class appearance = NSClassFromString(@"NSAppearance");
    Method m = appearance ? class_getInstanceMethod(appearance, sel_registerName("_coreUIRenderer")) : NULL;
    if (!m || strncmp(method_getTypeEncoding(m), "^", 1) != 0 ||
        !class_getInstanceMethod(appearance, sel_registerName("_isDefaultAppearance"))) return;
    orig_coreUIRenderer = (void *)method_setImplementation(m, (IMP)sl_coreUIRenderer);
}

// ---- button positions (NSThemeFrame) ---------------------------------------------------

static double (*orig_spacing)(id, SEL);
static double (*orig_minXInset)(id, SEL);
static double (*orig_minYOffset)(id, SEL);

// Only Mavericks' values for standard windows are changed; anything else
// (utility panels, other frame styles) is left as it is.
static double sl_spacing(id self, SEL _cmd)
{
    double v = orig_spacing(self, _cmd);
    return v == 6 && !SLFrameHasCustomAppearance(self) ? 7 : v;
}

static double sl_minXInset(id self, SEL _cmd)
{
    double v = orig_minXInset(self, _cmd);
    return v == 7 && !SLFrameHasCustomAppearance(self) ? 8 : v;
}

static double sl_minYOffset(id self, SEL _cmd)
{
    double v = orig_minYOffset(self, _cmd);
    return v == -2 && !SLFrameHasCustomAppearance(self) ? -1 : v;
}

static void SLHookLayout(void)
{
    Class frame = NSClassFromString(@"NSThemeFrame");
    struct { const char *name; IMP replacement; IMP *original; } hooks[] = {
        { "_windowTitlebarButtonSpacingWidth", (IMP)sl_spacing, (IMP *)&orig_spacing },
        { "_minXTitlebarWidgetInset", (IMP)sl_minXInset, (IMP *)&orig_minXInset },
        { "_minYTitlebarButtonsOffset", (IMP)sl_minYOffset, (IMP *)&orig_minYOffset },
    };
    for (unsigned i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        Method m = frame ? class_getInstanceMethod(frame, sel_registerName(hooks[i].name)) : NULL;
        // All three return a CGFloat; leave the layout alone unless they all exist.
        if (!m || strncmp(method_getTypeEncoding(m), "d", 1) != 0) return;
    }
    for (unsigned i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        Method m = class_getInstanceMethod(frame, sel_registerName(hooks[i].name));
        *hooks[i].original = method_setImplementation(m, hooks[i].replacement);
    }
}

// ---- title text (NSThemeFrame) -------------------------------------------------------------

static id (*orig_titleColor)(id, SEL);
static id (*orig_titleString)(id, SEL);
static void (*orig_drawTitle)(id, SEL, NSRect, id);

static BOOL SLFrameIsActive(NSView *frame)
{
    NSWindow *window = [frame window];
    return [window isKeyWindow] || [window isMainWindow];
}

static BOOL SLIsStandardTitleColor(NSColor *color)
{
    return [color isEqual:[NSColor windowFrameTextColor]];
}

static NSColor *SLTitleColor(NSView *frame)
{
    return SLFrameIsActive(frame) ? [NSColor blackColor] : [NSColor colorWithCalibratedWhite:0 alpha:0.63];
}

static id sl_titleColor(id self, SEL _cmd)
{
    id color = orig_titleColor(self, _cmd);
    // Only the standard title colour is replaced (not, say, a dark window's).
    return SLIsStandardTitleColor(color) && !SLFrameHasCustomAppearance(self) ? SLTitleColor(self) : color;
}

static id sl_titleString(id self, SEL _cmd)
{
    NSAttributedString *string = orig_titleString(self, _cmd);
    if (![string isKindOfClass:[NSAttributedString class]] || ![string length]) return string;
    static NSShadow *shadow;
    if (!shadow) {
        shadow = [[NSShadow alloc] init];
        [shadow setShadowColor:[NSColor colorWithCalibratedWhite:1 alpha:0.4]];
        [shadow setShadowOffset:NSMakeSize(0, -1)];
        [shadow setShadowBlurRadius:0];
    }
    if (!SLIsStandardTitleColor(orig_titleColor(self, sel_registerName("_currentTitleColor"))) || SLFrameHasCustomAppearance(self)) return string;
    NSMutableAttributedString *copy = [[string mutableCopy] autorelease];
    NSRange all = NSMakeRange(0, [copy length]);
    [copy addAttribute:NSForegroundColorAttributeName value:SLTitleColor(self) range:all];
    [copy addAttribute:NSShadowAttributeName value:shadow range:all];
    return copy;
}

// Mavericks draws the title with its cell's "raised" background style, which
// it renders with less contrast than 10.6 did; 10.6's raised look is just the
// shadow added above. Draw with the plain style and no LCD smoothing.
static void sl_drawTitle(id self, SEL _cmd, NSRect rect, id color)
{
    NSCell *cell = [self respondsToSelector:@selector(titleCell)] ? [self performSelector:@selector(titleCell)] : nil;
    BOOL restyle = [cell respondsToSelector:@selector(setBackgroundStyle:)] && [cell backgroundStyle] == NSBackgroundStyleRaised
                && [color isKindOfClass:[NSColor class]] && ![color isEqual:[NSColor whiteColor]];
    if (SLFrameHasCustomAppearance(self)) { orig_drawTitle(self, _cmd, rect, color); return; }
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    if (ctx) { CGContextSaveGState(ctx); CGContextSetShouldSmoothFonts(ctx, false); }
    if (restyle) [cell setBackgroundStyle:NSBackgroundStyleLight];
    orig_drawTitle(self, _cmd, rect, color);
    if (restyle) [cell setBackgroundStyle:NSBackgroundStyleRaised];
    if (ctx) CGContextRestoreGState(ctx);
}

// In layer-backed windows the title is a separate text field, which paints
// Mavericks' own title bar behind the text so it can use LCD smoothing; 10.6
// titles are not LCD smoothed, so let it draw just the text.
static BOOL sl_canSmoothFontsInLayer(id self, SEL _cmd)
{
    return NO;
}

static void SLHookTitle(void)
{
    Class field = NSClassFromString(@"NSThemeFrameTitleTextField");
    Method smooth = field ? class_getInstanceMethod(field, sel_registerName("canSmoothFontsInLayer")) : NULL;
    if (smooth && strncmp(method_getTypeEncoding(smooth), "c", 1) == 0)
        class_replaceMethod(field, sel_registerName("canSmoothFontsInLayer"), (IMP)sl_canSmoothFontsInLayer, method_getTypeEncoding(smooth));

    Class frame = NSClassFromString(@"NSThemeFrame");
    Method color = class_getInstanceMethod(frame, sel_registerName("_currentTitleColor"));
    Method string = class_getInstanceMethod(frame, sel_registerName("_currentTitleTextFieldAttributedString"));
    Method draw = class_getInstanceMethod(frame, sel_registerName("_drawTitleStringIn:withColor:"));
    if (!color || !string || !draw) return;
    orig_titleColor = (void *)method_setImplementation(color, (IMP)sl_titleColor);
    orig_titleString = (void *)method_setImplementation(string, (IMP)sl_titleString);
    orig_drawTitle = (void *)method_setImplementation(draw, (IMP)sl_drawTitle);
}

// ---- textured windows (NSThemeFrame) ---------------------------------------------------------

static id (*orig_cuiOptions)(id, SEL, CFStringRef, double, BOOL, double, BOOL);
static id (*orig_activeTextured)(id, SEL);
static id (*orig_inactiveTextured)(id, SEL);

static double SLFrameDouble(id frame, const char *selector)
{
    SEL sel = sel_registerName(selector);
    return [frame respondsToSelector:sel] ? ((double (*)(id, SEL))objc_msgSend)(frame, sel) : 0;
}

static BOOL SLFrameBool(id frame, const char *selector)
{
    SEL sel = sel_registerName(selector);
    return [frame respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(frame, sel);
}

// 10.6's top area for a textured window: Mavericks adds 75 points below the
// title bar when the window works out its own top border and has no toolbar;
// 10.6 added 2.
static double SLTexturedTopHeight(NSView *frame, double topHeight)
{
    NSWindow *window = [frame window];
    if (!window || ![window autorecalculatesContentBorderThicknessForEdge:NSMaxYEdge] || SLFrameBool(frame, "_toolbarIsShown"))
        return topHeight;
    double titlebar = SLFrameDouble(frame, "_titlebarHeight");
    return titlebar > 0 ? MIN(topHeight, titlebar + 2) : topHeight;
}

static id sl_cuiOptions(id self, SEL _cmd, CFStringRef windowType, double topHeight, BOOL separator, double bottomHeight, BOOL scale)
{
    if (windowType && CFEqual(windowType, CFSTR("kCUIWindowTypeTextured")) && !SLFrameHasCustomAppearance(self))
        topHeight = SLTexturedTopHeight(self, topHeight);
    return orig_cuiOptions(self, _cmd, windowType, topHeight, separator, bottomHeight, scale);
}

static NSColor *SLTexturedPattern(NSView *frame, BOOL active)
{
    double height = round([frame bounds].size.height);
    double top = round(SLTexturedTopHeight(frame, SLFrameDouble(frame, "_topHeightForTexturedBackground")));
    double bottom = round(SLFrameDouble(frame, "_bottomBarHeight"));
    if (height < 1) return nil;

    static NSMutableDictionary *cache;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSString *key = [NSString stringWithFormat:@"%g/%g/%g/%d/%g", height, top, bottom, active, [[frame window] backingScaleFactor]];
    NSColor *color = cache[key];
    if (color) return color;

    // At the window's backing scale, so the gradient is as fine as the frame's on Retina displays.
    CGFloat scale = MAX(1, round([[frame window] backingScaleFactor]));
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)scale pixelsHigh:(NSInteger)(height * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    [rep setSize:NSMakeSize(1, height)];
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext graphicsContextWithBitmapImageRep:rep] graphicsPort];
    CGContextScaleCTM(ctx, scale, scale);
    NSDictionary *o = @{ @"state": active ? @"normal" : @"inactive",
                         @"kCUIWindowFrameUnifiedTitleBarHeightKey": @(top),
                         @"kCUIWindowFrameBottomBarHeightKey": @(bottom) };
    SLDrawTexturedFrameInto(CGRectMake(0, 0, 1, height), ctx, o, NO);
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(1, height)] autorelease];
    [image addRepresentation:rep];
    color = [NSColor colorWithPatternImage:image];
    if ([cache count] > 64) [cache removeAllObjects];
    cache[key] = color;
    return color;
}

static id sl_activeTextured(id self, SEL _cmd)
{
    return (SLFrameHasCustomAppearance(self) ? nil : SLTexturedPattern(self, YES)) ?: orig_activeTextured(self, _cmd);
}

static id sl_inactiveTextured(id self, SEL _cmd)
{
    return (SLFrameHasCustomAppearance(self) ? nil : SLTexturedPattern(self, NO)) ?: orig_inactiveTextured(self, _cmd);
}

// A layer-backed window frame normally has CoreUI build it a tree of layers
// (CUICreateOrUpdateLayer) instead of drawing; have the frames of standard and
// textured titled windows draw, through CUIDraw, like any other view. (Menus
// and other untitled windows keep their layers.)
static BOOL (*orig_frameWantsUpdateLayer)(id, SEL);

static BOOL sl_frameWantsUpdateLayer(id self, SEL _cmd)
{
    NSWindow *window = [self window];
    NSUInteger mask = [window styleMask];
    if (window && (mask & NSTitledWindowMask) && !(mask & NSHUDWindowMask) && ![window isKindOfClass:NSClassFromString(@"NSCarbonMenuWindow")])
        return NO;
    return orig_frameWantsUpdateLayer(self, _cmd);
}



static void SLHookTextured(void)
{
    Class themeFrame = NSClassFromString(@"NSThemeFrame");
    Method wants = themeFrame ? class_getInstanceMethod(themeFrame, @selector(wantsUpdateLayer)) : NULL;
    if (wants) orig_frameWantsUpdateLayer = (void *)class_replaceMethod(themeFrame, @selector(wantsUpdateLayer), (IMP)sl_frameWantsUpdateLayer, method_getTypeEncoding(wants));
    if (!orig_frameWantsUpdateLayer && wants) orig_frameWantsUpdateLayer = (void *)method_getImplementation(wants);

    Class frame = NSClassFromString(@"NSThemeFrame");
    Method options = class_getInstanceMethod(frame, sel_registerName("_cuiOptionsForWindowType:topHeight:drawTopSeparator:bottomBarHeight:shouldSetScaleKey:"));
    Method active = class_getInstanceMethod(frame, sel_registerName("_activeTexturedWindowColor"));
    Method inactive = class_getInstanceMethod(frame, sel_registerName("_inactiveTexturedWindowColor"));
    if (!options || !active || !inactive) return;
    if (strcmp(method_getTypeEncoding(options), "@48@0:8^{__CFString=}16d24c32d36c44") != 0) return;
    orig_cuiOptions = (void *)method_setImplementation(options, (IMP)sl_cuiOptions);
    orig_activeTextured = (void *)method_setImplementation(active, (IMP)sl_activeTextured);
    orig_inactiveTextured = (void *)method_setImplementation(inactive, (IMP)sl_inactiveTextured);
}

// ---- tabs (Safari, Finder) ------------------------------------------------------------
//
// Safari's and Finder's tab bars are drawn from images of their own, named
// "AW ..." in the main window and "IW ..." in others (the selected tab, the
// others behind it, close and add buttons), made to continue the toolbar: the
// selected tab hangs from it. Mavericks' are Safari 4's images, of the same
// names, retextured; so +[NSImage imageNamed:] hands out Safari 4's own (from
// the 10.6 install DVD; see extract.sh), which continue 10.6's toolbar exactly.
// Finder calls the tabs behind the selected one "InactiveTabFill" (Safari 4:
// "InactiveTabBG"). The one image 10.6 has no counterpart for, the tab-shaped
// new-tab button shown with a single tab, keeps its outline in 10.6's tones.

static id (*orig_imageNamed)(id, SEL, NSString *);
// 10.6's own tab art (Safari 4's, taken from the install DVD by extract.sh),
// by the same names, where it has the image.
static NSString *SLSnowLeopardTabPath(NSString *name)
{
    NSString *dir = [[gSLBundlePath stringByAppendingPathComponent:@"Contents/Resources"] stringByAppendingPathComponent:@"SLTabArt"];
    NSString *path = [[dir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"png"];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

static NSBitmapImageRep *SLBitmapOf(NSImageRep *rep)
{
    NSInteger w = [rep pixelsWide], h = [rep pixelsHigh];
    if (w <= 0 || h <= 0) return nil;
    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32] autorelease];
    [bitmap setSize:[rep size]];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    [rep drawInRect:NSMakeRect(0, 0, [rep size].width, [rep size].height)];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

// The rows of an image's last column, as gray (premultiplied, so where opaque).
static int SLColumnRows(NSBitmapImageRep *bitmap, double *gray, int max)
{
    int w = (int)[bitmap pixelsWide], h = MIN(max, (int)[bitmap pixelsHigh]);
    unsigned char *p = [bitmap bitmapData];
    for (int y = 0; y < h; y++) gray[y] = p[(y * w + w - 1) * 4 + 1];
    return h;
}

// Mavericks' tab-shaped new-tab button (shown at the end of the bookmarks bar
// when there is one tab), which 10.6 has no image for, in 10.6's tones: its
// outline kept, its noise texture removed, and each row recoloured to the
// matching row of a 10.6 tab image - top border, gradient, bottom highlight -
// with the + keeping its relative darkness.
static NSImage *SLRetonedTabButton(NSImage *image, NSString *referenceName)
{
    NSString *path = SLSnowLeopardTabPath(referenceName);
    NSImage *reference = path ? [[[NSImage alloc] initWithContentsOfFile:path] autorelease] : nil;
    NSBitmapImageRep *ref = [[reference representations] count] ? SLBitmapOf([[reference representations] objectAtIndex:0]) : nil;
    if (!ref) return nil;
    double refRows[256];
    int refH = SLColumnRows(ref, refRows, 256);
    int rt = -1, rb = -1;             // the reference's top border and bottom highlight rows (its opaque span)
    unsigned char *rp = [ref bitmapData];
    for (int y = 0; y < refH; y++) {
        if (rp[(y * [ref pixelsWide] + [ref pixelsWide] - 1) * 4 + 3] > 240) { if (rt < 0) rt = y; rb = y; }
    }
    if (rt < 0 || rb - rt < 3) return nil;

    NSImage *copy = [[[NSImage alloc] initWithSize:[image size]] autorelease];
    for (NSImageRep *rep in [image representations]) {
        NSBitmapImageRep *bitmap = SLBitmapOf(rep);
        if (!bitmap) return nil;
        int w = (int)[bitmap pixelsWide], h = (int)[bitmap pixelsHigh];
        unsigned char *p = [bitmap bitmapData];
        // The button's own opaque span, along its last column.
        int t = -1, b = -1;
        for (int y = 0; y < h; y++) if (p[(y * w + w - 1) * 4 + 3] > 240) { if (t < 0) t = y; b = y; }
        if (t < 0 || b - t < 3) return nil;
        for (int y = t; y <= b; y++) {
            // This row's body tone: the median of its opaque right half.
            int hist[256] = { 0 }, n = 0;
            for (int x = w / 2; x < w; x++) if (p[(y * w + x) * 4 + 3] > 240) { hist[p[(y * w + x) * 4 + 1]]++; n++; }
            if (!n) continue;
            int median = 0;
            for (int c = 0, k = 0; c < 256; c++) { k += hist[c]; if (k * 2 >= n) { median = c; break; } }
            // The matching reference row: border to border, gradient to gradient.
            double target;
            if (y == t) target = refRows[rt];
            else if (y == b) target = refRows[rb];
            else {
                double f = (double)(y - t - 1) / MAX(1, b - t - 2);
                double r = (rt + 1) + f * ((rb - 1) - (rt + 1));
                int r0 = (int)floor(r), r1 = MIN(r0 + 1, rb - 1);
                target = refRows[r0] + (r - r0) * (refRows[r1] - refRows[r0]);
            }
            double delta = target - median;
            for (int x = 0; x < w; x++) {
                unsigned char *q = p + (y * w + x) * 4;
                if (!q[3]) continue;
                double a = q[3] / 255.0, v = q[1];
                // Body pixels (close to the row's tone; the outline and the +
                // differ by far more than the noise does) lose their noise.
                if (q[3] > 240 && fabs(v - median) < 14) v = median;
                v = MAX(0, MIN(255 * a, v + delta * a));
                q[0] = q[1] = q[2] = (unsigned char)lround(v);
            }
        }
        [copy addRepresentation:bitmap];
    }
    return copy;
}

// Apps' own title bar buttons, drawn from images of their own, in 10.6's
// size and style. QuickTime Player's ("close-active-color" and so on) are
// QuickTime Player X's from 10.6, the same images by the same names (taken
// from the install DVD by extract.sh): 10.6's fill their 14 x 16 canvas with a
// 14-point button, Mavericks' are 12 points. Apps 10.6 didn't have get
// 10.6's buttons too: QuickTime Player X's in dark title bars (its art is
// made for one: darker rims, deeper colours) - FaceTime and Reminders use the
// same names - and 10.6's standard ones in light title bars: iBooks has its
// own names, <Aqua|Graphite><state><button> in its library window
// (IMPlatformCore) and ib_tb_Aqua<state><button> in its reader
// (BKPlatformCore), which has its three inactive buttons as one image too,
// ib_tb_traffic_lights-inactive-N, in each of its themes (its night theme's
// title bar is dark).
static NSString *SLQuickTimeArtPath(NSString *name)
{
    if ([name rangeOfString:@"/"].location != NSNotFound) return nil;
    NSString *dir = [[gSLBundlePath stringByAppendingPathComponent:@"Contents/Resources"] stringByAppendingPathComponent:@"SLQuickTimeArt"];
    NSString *path = [[dir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"tiff"];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

static NSImage *SLQuickTimeArt(NSString *name)
{
    NSString *path = SLQuickTimeArtPath(name);
    return path ? [[[NSImage alloc] initWithContentsOfFile:path] autorelease] : nil;
}

static NSString *SLAppIdentifier(void)
{
    static NSString *app;
    if (!app) app = [[[NSBundle mainBundle] bundleIdentifier] copy] ?: @"";
    return app;
}

// 10.6's standard title bar button (as drawn in windows by sl_CUIDraw), as an
// image with its 1x and 2x art: widget "titlebarclose", "titlebarcollapse" or
// "titlebarzoom"; colors "aqua" or "graphite"; state as in SLWindowArt.bin.
static NSImage *SLStandardButton(NSString *widget, NSString *colors, NSString *state)
{
    NSString *name = [NSString stringWithFormat:@"regularwin/%@/%@/%@", widget, colors, state];
    CGImageRef image1x = SLArtImage(name), image2x = SLArt2xImage(name);
    if (!image1x) return nil;
    NSSize size = NSMakeSize(CGImageGetWidth(image1x), CGImageGetHeight(image1x));
    NSImage *image = [[[NSImage alloc] initWithSize:size] autorelease];
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:image1x] autorelease];
    [rep setSize:size];
    [image addRepresentation:rep];
    if (image2x) {
        rep = [[[NSBitmapImageRep alloc] initWithCGImage:image2x] autorelease];
        [rep setSize:size];
        [image addRepresentation:rep];
    }
    return image;
}

// Images drawn side by side, `spacing` points apart, at 1x and 2x.
static NSImage *SLSideBySide(NSArray *images, CGFloat spacing)
{
    NSSize button = [(NSImage *)images[0] size];
    NSSize size = NSMakeSize(spacing * ([images count] - 1) + button.width, button.height);
    NSImage *result = [[[NSImage alloc] initWithSize:size] autorelease];
    for (int scale = 1; scale <= 2; scale++) {
        NSInteger w = (NSInteger)(scale * size.width), h = (NSInteger)(scale * size.height);
        NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32] autorelease];
        [bitmap setSize:size];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        for (NSUInteger i = 0; i < [images count]; i++) {
            NSImage *image = images[i];
            // The representation for this scale, drawn at the image's size.
            NSImageRep *best = nil;
            for (NSImageRep *rep in [image representations]) if ([rep pixelsWide] == scale * [image size].width) best = rep;
            [(NSImageRep *)(best ?: [[image representations] lastObject]) drawInRect:NSMakeRect(i * spacing, 0, [image size].width, [image size].height)];
        }
        [NSGraphicsContext restoreGraphicsState];
        [result addRepresentation:bitmap];
    }
    return result;
}

// QuickTime Player X's buttons are 1x only, and differ from 10.6's standard
// ones (which have 2x renders): darker rims, made for a dark title bar. On
// Retina displays the app's own (Mavericks') buttons are drawn instead of
// QuickTime Player X's scaled up: the replacement carries QuickTime Player X's
// 1x image and the original's 2x one, and AppKit picks by the display. The
// original's 2x image is centred in a canvas of the replacement's size, for
// iBooks' three-button image, whose canvas differs.
static NSImage *SLWithOriginalRetina(NSImage *replacement, NSImage *original)
{
    if (!replacement || !original) return replacement;
    NSSize size = [replacement size], originalSize = [original size];
    NSImage *image = [[[NSImage alloc] initWithSize:size] autorelease];
    for (NSImageRep *rep in [replacement representations])
        if ([rep pixelsWide] <= size.width) [image addRepresentation:rep];
    for (NSImageRep *rep in [original representations]) {
        if ([rep pixelsWide] < 2 * originalSize.width) continue;
        NSInteger w = (NSInteger)(2 * size.width), h = (NSInteger)(2 * size.height);
        NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32] autorelease];
        [bitmap setSize:size];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        [rep drawInRect:NSMakeRect(round((size.width - originalSize.width) / 2), round((size.height - originalSize.height) / 2),
                                   originalSize.width, originalSize.height)];
        [NSGraphicsContext restoreGraphicsState];
        [image addRepresentation:bitmap];
        break;
    }
    return image;
}

// QuickTime Player X's art for an app's own image name, with the app's own
// (Mavericks') 2x image for Retina displays.
static NSImage *SLQuickTimeButton(NSString *name, NSImage *original)
{
    return SLWithOriginalRetina(SLQuickTimeArt(name), original);
}

// An app's own title bar button image, by name, in 10.6's style; nil if the
// app or name isn't one of these.
static NSImage *SLAppButtonImage(NSString *name, NSImage *original)
{
    NSString *app = SLAppIdentifier();
    // Dark title bars: QuickTime Player X's buttons, by QuickTime Player's names.
    if ([app isEqualToString:@"com.apple.QuickTimePlayerX"] || [app isEqualToString:@"com.apple.FaceTime"] || [app isEqualToString:@"com.apple.reminders"])
        return SLQuickTimeButton(name, original);
    // iBooks' light title bars: 10.6's standard buttons.
    if ([app isEqualToString:@"com.apple.iBooksX"]) {
        if ([name hasPrefix:@"ib_tb_"] && [name hasSuffix:@"traffic_lights-inactive-N"]) {
            if ([name hasPrefix:@"ib_tb_night_"]) {     // its night theme's dark title bar
                NSArray *images = @[ SLQuickTimeArt(@"close-inactive-disabled-color"), SLQuickTimeArt(@"minimize-inactive-disabled-color"),
                                     SLQuickTimeArt(@"zoom-inactive-disabled-color") ];
                return SLWithOriginalRetina(SLSideBySide(images, 20), original);
            }
            return SLSideBySide(@[ SLStandardButton(@"titlebarclose", @"aqua", @"inactive"), SLStandardButton(@"titlebarcollapse", @"aqua", @"inactive"),
                                   SLStandardButton(@"titlebarzoom", @"aqua", @"inactive") ], 20);
        }
        NSString *rest = [name hasPrefix:@"ib_tb_"] ? [name substringFromIndex:6] : name;
        static NSDictionary *tints, *states, *buttons;
        if (!tints) {
            tints = [@{ @"Aqua": @"aqua", @"Graphite": @"graphite" } retain];
            states = [@{ @"Normal": @"active", @"Hover": @"rollover", @"Pressed": @"pressed", @"Inactive": @"inactive" } retain];
            buttons = [@{ @"Close": @"titlebarclose", @"Minimize": @"titlebarcollapse", @"Zoom": @"titlebarzoom" } retain];
        }
        for (NSString *tint in tints)
            for (NSString *state in states)
                for (NSString *button in buttons)
                    if ([rest isEqualToString:[NSString stringWithFormat:@"%@%@%@", tint, state, button]])
                        return SLStandardButton(buttons[button], tints[tint], states[state]);
    }
    return nil;
}

static id SLReplacementImage(NSImage *image, NSString *name)
{
    if ([name hasPrefix:@"AW "] || [name hasPrefix:@"IW "]) {
        NSString *prefix = [name substringToIndex:3], *rest = [name substringFromIndex:3];
        // Finder's name for the tabs behind the selected one.
        if ([rest isEqualToString:@"InactiveTabFill"]) rest = @"InactiveTabBG";
        NSString *path = SLSnowLeopardTabPath([prefix stringByAppendingString:rest]);
        if (path) return [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
        if ([rest isEqualToString:@"SingleTabAddButton"])
            return SLRetonedTabButton(image, [prefix stringByAppendingString:@"InactiveTabBG"]);
        if ([rest isEqualToString:@"SingleTabAddButtonRollover"])
            return SLRetonedTabButton(image, [prefix stringByAppendingString:@"AddTabButtonRolloverBG"]);
        if ([rest isEqualToString:@"SingleTabAddButtonPressed"])
            return SLRetonedTabButton(image, [prefix stringByAppendingString:@"AddTabButtonRolloverBG Pressed"]);
        return nil;
    }
    return SLAppButtonImage(name, image);
}

static id SLReplaced(NSImage *image, NSString *name)
{
    if (!image || ![name isKindOfClass:[NSString class]]) return image;
    static NSMutableDictionary *cache;
    @synchronized ([NSImage class]) {
        if (!cache) cache = [[NSMutableDictionary alloc] init];
        id replacement = cache[name];
        if (!replacement) cache[name] = replacement = SLReplacementImage(image, name) ?: (id)[NSNull null];   // NSNull: 10.6 has nothing for it
        return replacement != [NSNull null] ? replacement : image;
    }
}

static id sl_imageNamed(id self, SEL _cmd, NSString *name)
{
    return SLReplaced(orig_imageNamed(self, _cmd, name), name);
}

// Images an app's frameworks load from their own bundles (iBooks').
static id (*orig_imageForResource)(id, SEL, NSString *);

static id sl_imageForResource(id self, SEL _cmd, NSString *name)
{
    return SLReplaced(orig_imageForResource(self, _cmd, name), name);
}

static void SLHookTabArt(void)
{
    Method m = class_getClassMethod([NSImage class], @selector(imageNamed:));
    if (m) orig_imageNamed = (void *)method_setImplementation(m, (IMP)sl_imageNamed);
    m = class_getInstanceMethod([NSBundle class], @selector(imageForResource:));
    if (m) orig_imageForResource = (void *)method_setImplementation(m, (IMP)sl_imageForResource);
}

static id (*orig_appInit)(id, SEL);

static void SLSetUp(void)
{
    static BOOL done = NO;
    if (done) return;
    done = YES;
    if (!SLLoadArt()) return;           // (the core says so)
    SLHookAppearance();
    SLHookLayout();
    SLHookTitle();
    SLHookTextured();
    SLHookTabArt();
}

static id sl_appInit(id self, SEL _cmd)
{
    self = orig_appInit(self, _cmd);
    if (self && [NSThread isMainThread]) SLSetUp();
    return self;
}

/* Nothing is set up until the process has its application object. MIP can
   load the plugin before that exists (AppKit's open/save panel service checks
   in with Launch Services and then waits for a client before creating NSApp
   and its window server connection); touching the window server in between
   breaks that service. So: with NSApp already there (normal applications,
   where MIP loads the plugin inside -[NSApplication init]), set up now;
   otherwise as soon as -[NSApplication init] returns. Called by the core
   (SLWindowsCore.m) once the process has AppKit. */
__attribute__((visibility("default"))) void SLWindowsAppKitStart(const char *bundlePath, SLRegisterRendererFn registerRenderer)
{
    if (floor(NSAppKitVersionNumber) != 1265) return;     // Mavericks' AppKit only
    gSLBundlePath = [[NSString alloc] initWithUTF8String:bundlePath];
    gRegisterRenderer = registerRenderer;
    if (NSApp && [NSThread isMainThread]) {
        SLSetUp();
    } else {
        Method init = class_getInstanceMethod([NSApplication class], @selector(init));
        if (init) orig_appInit = (void *)method_setImplementation(init, (IMP)sl_appInit);
    }
}
