//
//  SLWindows.m
//  Snow Leopard window title bars and title bar buttons for Mavericks (MIP plugin).
//
//  AppKit draws window chrome through CoreUI's CUIDraw(), naming the part in
//  the options dictionary:
//
//    titlebarclose, titlebarcollapse,   the title bar buttons; "state" (normal,
//    titlebarzoom, titlebartoolbar      rollover, pressed, disabled),
//                                       kCUIPresentationStateKey (ActiveKey,
//                                       ActiveMain, Inactive), "value" (1 when
//                                       the document has unsaved changes),
//                                       "windowtype" (regularwin, utilwin.*)
//    kCUIWidgetWindowFrame              the title bar / unified toolbar
//                                       background
//
//  Snow Leopard's CoreUI took the same options. This plugin hooks CUIDraw and
//  draws those parts as 10.6 did; everything else goes to CoreUI unchanged.
//
//  Buttons: 10.6's own images, extracted at build time from Snow Leopard's
//  ArtFile.bin (see extract_art.py), drawn exactly as stored, at 10.6's
//  positions: in standard windows 10.6 spaced them 7 points apart (Mavericks 6),
//  8 points from the left edge (Mavericks 7) and a point lower. Utility panels
//  are laid out the same in both.
//
//  Title: 10.6 drew it in black (black at 63% opacity in an inactive window),
//  with a white shadow one point below and without LCD font smoothing.
//
//  Title bar: 10.6 fills it with CUIRenderer::CreateGrayCubicGradientImage,
//      v(t) = s + D(t^3 - 1.5t^2 - 0.5t),  D = s - e,
//  from gray 197 to 150 (active) or 233 to 207 (inactive), as an 8-bit gray
//  image that the system colour-matches to the display like any other art.
//  Row 0 is a highlight (40% white over the gradient) and, when CoreUI is asked
//  for a title separator, the last row is the separator line (gray 63, or 135
//  when inactive). These values (from 10.6's CoreUI code and colour table)
//  reproduce 10.6 screenshots of active title bars and unified toolbars of any
//  height, and of inactive ones.
//
//  Bottom bar (kCUIWidgetWindowBottomBar): the same, from 191 to 150 (229 to 207
//  inactive) below a separator. Toolbar baseline (kCUIWidgetToolbarBaselineSeparator):
//  the separator line.
//
//  Textured windows (kCUIWindowTypeTextured; the frame request covers the whole
//  window): flat gray 150 (207 inactive), the title bar gradient over the top
//  area, and at the bottom either the bottom bar gradient or, without a bottom
//  bar, 10 rows from 150 to 125 (207 to 182 inactive). They use the standard
//  title bar buttons, as in 10.6. Without a toolbar the top area is the title
//  bar plus 2 points (Mavericks extends it by 75), and the window's background
//  pattern, which some views paint behind themselves, is drawn the same way.
//
//  Apps with their own look: an app can give a window its own NSAppearance,
//  built from a CoreUI catalog of its own (Reminders' leather, for one); CoreUI
//  then draws that window's chrome with the appearance's renderer. Those
//  renderers are passed through untouched, and such windows also keep
//  Mavericks' button positions, title and textured background: only the
//  standard (default) appearance gets Snow Leopard's.
//

#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <libkern/OSAtomic.h>

// CUIDraw returns an OSStatus (callers such as HIToolbox's menu drawing check it).
typedef OSStatus (*SLCUIDrawFn)(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result);
typedef void (*SLHookFunctionFn)(void *symbol, void *replacement, void **original);

static SLCUIDrawFn orig_CUIDraw;
static CFDictionaryRef gArt;            // image name -> CGImageRef
static CFDictionaryRef gArt2x;          // the same at 2x, for Retina displays (may be empty)
static CGColorSpaceRef gColorSpace;     // Generic RGB, as 10.6's CoreUI art

@interface SLWindows : NSObject
@end

// ---- art ------------------------------------------------------------------------

static CFDictionaryRef SLReadArtFile(NSString *resource)
{
    NSString *path = [[NSBundle bundleForClass:[SLWindows class]] pathForResource:resource ofType:@"bin"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    const uint8_t *d = [data bytes];
    size_t len = [data length], p = 8;
    if (len < 8 || memcmp(d, "SLWA", 4) != 0) return NULL;
    uint32_t count = OSReadLittleInt32(d, 4);

    CFMutableDictionaryRef art = CFDictionaryCreateMutable(NULL, count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (uint32_t i = 0; i < count; i++) {
        if (p + 2 > len) break;
        uint16_t nameLength = OSReadLittleInt16(d, p);
        if (p + 2 + nameLength + 4 > len) break;
        CFStringRef name = CFStringCreateWithBytes(NULL, d + p + 2, nameLength, kCFStringEncodingASCII, false);
        uint16_t w = OSReadLittleInt16(d, p + 2 + nameLength), h = OSReadLittleInt16(d, p + 4 + nameLength);
        size_t start = p + 6 + nameLength, size = (size_t)w * h * 4;
        if (start + size > len || !name) { if (name) CFRelease(name); break; }

        // Premultiplied ARGB, as CoreUI stores it.
        CFDataRef pixels = CFDataCreate(NULL, d + start, size);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
        CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, gColorSpace,
                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big,
                                         provider, NULL, false, kCGRenderingIntentDefault);
        if (image) CFDictionarySetValue(art, name, image);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CFRelease(pixels);
        CFRelease(name);
        p = start + size;
    }
    return art;
}

// SLWindowArt.bin: 10.6's 1x images. SLWindowArt@2x.bin (optional): the same
// images at 2x, rendered at build time from 10.6's recipes (render_hidpi.m).
static BOOL SLLoadArt(void)
{
    gColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    gArt = SLReadArtFile(@"SLWindowArt");
    if (!gArt || CFDictionaryGetCount(gArt) == 0) return NO;
    gArt2x = SLReadArtFile(@"SLWindowArt@2x");
    return YES;
}

static CGImageRef SLArtImage(NSString *name)
{
    return (CGImageRef)CFDictionaryGetValue(gArt, (CFStringRef)name);
}

// Device pixels per point vertically (2 on Retina displays).
static int SLContextScale(CGContextRef ctx);

// ---- title bar buttons --------------------------------------------------------------

static NSString *SLButtonImageName(NSDictionary *o)
{
    NSString *widget = o[@"widget"];
    NSString *windowType = o[@"windowtype"] ?: @"regularwin";
    if ([windowType isEqualToString:@"kCUIWindowTypeTextured"]) windowType = @"regularwin";
    if ([widget isEqualToString:@"titlebarclose"] && [o[@"value"] intValue] != 0) widget = @"titlebarclosedirty";
    NSString *colors = [NSColor currentControlTint] == NSGraphiteControlTint ? @"graphite" : @"aqua";

    NSString *state = o[@"state"];
    NSString *presentation = o[@"kCUIPresentationStateKey"];
    NSArray *states;
    if ([state isEqualToString:@"disabled"]) states = @[@"disabled"];
    else if ([state isEqualToString:@"pressed"]) states = @[@"pressed"];
    else if ([state isEqualToString:@"rollover"]) states = @[@"rollover"];
    else if ([presentation isEqualToString:@"kCUIPresentationStateInactive"]) states = @[@"inactive"];
    else if ([presentation isEqualToString:@"kCUIPresentationStateActiveMain"]) states = @[@"activenokey", @"active"];
    else states = @[@"active", @"key", @"normal"];

    for (NSString *s in states) {
        NSString *name = [NSString stringWithFormat:@"%@/%@/%@/%@", windowType, widget, colors, s];
        if (SLArtImage(name)) return name;
    }
    return nil;
}

static void SLDrawButton(NSString *name, CGRect rect, CGContextRef ctx, BOOL flipped)
{
    CGImageRef image = SLArtImage(name);
    CGFloat w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    // On a Retina display, the 2x rendering of the same image in the same place.
    CGImageRef image2x = gArt2x && SLContextScale(ctx) >= 2 ? (CGImageRef)CFDictionaryGetValue(gArt2x, (CFStringRef)name) : NULL;
    if (image2x && CGImageGetWidth(image2x) == 2 * w && CGImageGetHeight(image2x) == 2 * h) image = image2x;
    // 10.6's images include the button's shadow; centre horizontally, top aligned.
    CGFloat x = rect.origin.x + floor((rect.size.width - w) / 2);
    CGFloat top = MAX(0, floor((rect.size.height - h) / 2));
    CGContextSaveGState(ctx);
    if (flipped) {
        CGContextTranslateCTM(ctx, x, rect.origin.y + top + h);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    } else {
        CGContextDrawImage(ctx, CGRectMake(x, CGRectGetMaxY(rect) - top - h, w, h), image);
    }
    CGContextRestoreGState(ctx);
}

// ---- title bar background -----------------------------------------------------------------

static double SLSeparatorGray(BOOL active)
{
    return active ? 63 : 135;
}

static void SLFillRow(CGContextRef ctx, CGRect rect, int r, BOOL flipped, double gray)
{
    CGFloat v = round(gray) / 255;
    CGFloat components[] = { v, v, v, 1 };
    CGColorRef color = CGColorCreate(gColorSpace, components);
    CGContextSetFillColorWithColor(ctx, color);
    CGColorRelease(color);
    CGFloat y = flipped ? rect.origin.y + r : CGRectGetMaxY(rect) - 1 - r;
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, y, rect.size.width, 1));
}

// Device pixels per point vertically (2 on Retina displays).
static int SLContextScale(CGContextRef ctx)
{
    CGAffineTransform m = CGContextGetUserSpaceToDeviceSpaceTransform(ctx);
    double scale = sqrt(m.c * m.c + m.d * m.d);
    return scale >= 1.5 ? (int)lround(scale) : 1;
}

// 10.6's cubic gradient from s to e over `count` point rows starting at
// row `first`, evaluated at the centre of every device pixel row.
static void SLFillGradient(CGContextRef ctx, CGRect rect, int first, int count, BOOL flipped, double s, double e)
{
    int scale = SLContextScale(ctx), n = count * scale;
    double D = s - e;
    for (int j = 0; j < n; j++) {
        double t = (j + 0.5) / n;
        CGFloat v = round(D * t * t * t - 1.5 * D * t * t - 0.5 * D * t + s) / 255;
        CGFloat components[] = { v, v, v, 1 };
        CGColorRef color = CGColorCreate(gColorSpace, components);
        CGContextSetFillColorWithColor(ctx, color);
        CGColorRelease(color);
        CGFloat h = 1.0 / scale, offset = first + (CGFloat)j / scale;
        CGFloat y = flipped ? rect.origin.y + offset : CGRectGetMaxY(rect) - offset - h;
        CGContextFillRect(ctx, CGRectMake(rect.origin.x, y, rect.size.width, h));
    }
}

static void SLDrawBottomBar(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL active = ![o[@"state"] isEqualToString:@"inactive"];
    BOOL separator = [o[@"kCUIWindowFrameDrawBottomBarSeparatorKey"] boolValue];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    int rows = (int)lround(rect.size.height);
    int n = rows - (separator ? 1 : 0);
    if (n < 1) return;
    double s = active ? 191 : 229, e = active ? 150 : 207;
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    if (separator) SLFillRow(ctx, rect, 0, flipped, SLSeparatorGray(active));
    SLFillGradient(ctx, rect, separator ? 1 : 0, n, flipped, s, e);
    CGContextRestoreGState(ctx);
}

static void SLDrawToolbarSeparator(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL active = ![o[@"kCUIPresentationStateKey"] isEqualToString:@"kCUIPresentationStateInactive"];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    // The line is the toolbar's last row.
    SLFillRow(ctx, rect, (int)lround(rect.size.height) - 1, flipped, SLSeparatorGray(active));
}

static void SLDrawTexturedFrameInto(CGRect rect, CGContextRef ctx, NSDictionary *o, BOOL atop)
{
    BOOL active = ![o[@"state"] isEqualToString:@"inactive"];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    int rows = (int)lround(rect.size.height);
    int top = MIN(rows, (int)lround([o[@"kCUIWindowFrameUnifiedTitleBarHeightKey"] doubleValue]));
    int barHeight = (int)lround([o[@"kCUIWindowFrameBottomBarHeightKey"] doubleValue]);
    int bottom = MIN(rows - top, barHeight > 0 ? barHeight : 10);
    double flat = active ? 150 : 207;
    double ts = active ? 197 : 233;
    double bs = barHeight > 0 ? (active ? 191 : 229) : flat, be = barHeight > 0 ? (active ? 150 : 207) : flat - 25;

    CGContextSaveGState(ctx);
    if (atop) CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    CGFloat v = flat / 255, components[] = { v, v, v, 1 };
    CGColorRef color = CGColorCreate(gColorSpace, components);
    CGContextSetFillColorWithColor(ctx, color);
    CGColorRelease(color);
    CGContextFillRect(ctx, rect);
    if (top > 1) {
        SLFillRow(ctx, rect, 0, flipped, ts + 0.4 * (255 - ts));
        SLFillGradient(ctx, rect, 1, top - 1, flipped, ts, flat);
    }
    if (bottom > 0) SLFillGradient(ctx, rect, rows - bottom, bottom, flipped, bs, be);
    CGContextRestoreGState(ctx);
}

static void SLDrawTexturedFrame(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    SLDrawTexturedFrameInto(rect, ctx, o, YES);
}

static void SLDrawTitleBar(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL active = ![o[@"state"] isEqualToString:@"inactive"];
    BOOL separator = [o[@"kCUIWindowFrameDrawTitleSeparatorKey"] boolValue];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    int rows = (int)lround(rect.size.height);
    int n = rows - 1 - (separator ? 1 : 0);
    if (n < 1) return;

    double s = active ? 197 : 233, e = active ? 150 : 207;
    double highlight = s + 0.4 * (255 - s);

    CGContextSaveGState(ctx);
    // Only where CoreUI has just drawn the title bar, so the window keeps its
    // rounded corners and outline.
    CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    SLFillRow(ctx, rect, 0, flipped, highlight);
    SLFillGradient(ctx, rect, 1, n, flipped, s, e);
    for (int r = n + 1; r < rows; r++) SLFillRow(ctx, rect, r, flipped, SLSeparatorGray(active));
    CGContextRestoreGState(ctx);
}

// ---- windows with their own appearance ---------------------------------------------------

// The CoreUI renderers of non-default NSAppearances (an app's own theme), as
// they are handed out; CUIDraw passes their drawing through unchanged.
static CFMutableSetRef gCustomRenderers;
static OSSpinLock gCustomRenderersLock = OS_SPINLOCK_INIT;
static void *(*orig_coreUIRenderer)(id, SEL);

static BOOL SLIsDefaultAppearance(id appearance)
{
    SEL sel = sel_registerName("_isDefaultAppearance");
    return !appearance || ![appearance respondsToSelector:sel] || ((BOOL (*)(id, SEL))objc_msgSend)(appearance, sel);
}

static void *sl_coreUIRenderer(id self, SEL _cmd)
{
    void *renderer = orig_coreUIRenderer(self, _cmd);
    if (renderer && !SLIsDefaultAppearance(self)) {
        OSSpinLockLock(&gCustomRenderersLock);
        CFSetAddValue(gCustomRenderers, renderer);
        OSSpinLockUnlock(&gCustomRenderersLock);
    }
    return renderer;
}

static BOOL SLIsCustomRenderer(CFTypeRef renderer)
{
    if (!renderer || !gCustomRenderers) return NO;
    OSSpinLockLock(&gCustomRenderersLock);
    BOOL custom = CFSetContainsValue(gCustomRenderers, renderer);
    OSSpinLockUnlock(&gCustomRenderersLock);
    return custom;
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
    gCustomRenderers = CFSetCreateMutable(NULL, 0, NULL);
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
// the 10.6 install DVD; see build.sh), which continue 10.6's toolbar exactly.
// Finder calls the tabs behind the selected one "InactiveTabFill" (Safari 4:
// "InactiveTabBG"). The one image 10.6 has no counterpart for, the tab-shaped
// new-tab button shown with a single tab, keeps its outline in 10.6's tones.
//
// Without Safari 4's images, Mavericks' are darkened to suit 10.6's toolbar,
// which ends darker: the selected tab is about 175 on screen (223 in an
// inactive window) where 10.6's toolbar ends at 168 (216).

static id (*orig_imageNamed)(id, SEL, NSString *);
static NSImage *SLDarkenedImage(NSImage *image, CGFloat scale)
{
    NSImage *copy = [[NSImage alloc] initWithSize:[image size]];
    for (NSImageRep *rep in [image representations]) {
        NSInteger w = [rep pixelsWide], h = [rep pixelsHigh];
        if (w <= 0 || h <= 0) { [copy release]; return image; }
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
        [bitmap setSize:[rep size]];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        [rep drawInRect:NSMakeRect(0, 0, [rep size].width, [rep size].height)];
        [NSGraphicsContext restoreGraphicsState];
        unsigned char *p = [bitmap bitmapData];
        for (NSInteger i = 0; i < w * h; i++, p += 4)      // premultiplied RGBA: scale the colour
            for (int c = 0; c < 3; c++) p[c] = (unsigned char)lround(p[c] * scale);
        [copy addRepresentation:bitmap];
        [bitmap release];
    }
    return [copy autorelease];
}

// 10.6's own tab art (Safari 4's, taken from the install DVD at build time;
// see build.sh), by the same names, where it has the image.
static NSString *SLSnowLeopardTabPath(NSString *name)
{
    NSString *dir = [[[NSBundle bundleForClass:[SLWindows class]] resourcePath] stringByAppendingPathComponent:@"SLTabArt"];
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

static id sl_imageNamed(id self, SEL _cmd, NSString *name)
{
    NSImage *image = orig_imageNamed(self, _cmd, name);
    if (!image || ![name isKindOfClass:[NSString class]]) return image;
    if ([name hasPrefix:@"AW "] || [name hasPrefix:@"IW "]) {
        static NSMutableDictionary *originals;
        @synchronized ([NSImage class]) {
            if (!originals) originals = [[NSMutableDictionary alloc] init];
            id original = originals[name];
            if (!original) {
                NSString *prefix = [name substringToIndex:3], *rest = [name substringFromIndex:3];
                // Finder's name for the tabs behind the selected one.
                if ([rest isEqualToString:@"InactiveTabFill"]) rest = @"InactiveTabBG";
                NSString *path = SLSnowLeopardTabPath([prefix stringByAppendingString:rest]);
                if (path) original = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
                else if ([rest isEqualToString:@"SingleTabAddButton"])
                    original = SLRetonedTabButton(image, [prefix stringByAppendingString:@"InactiveTabBG"]);
                else if ([rest isEqualToString:@"SingleTabAddButtonRollover"])
                    original = SLRetonedTabButton(image, [prefix stringByAppendingString:@"AddTabButtonRolloverBG"]);
                else if ([rest isEqualToString:@"SingleTabAddButtonPressed"])
                    original = SLRetonedTabButton(image, [prefix stringByAppendingString:@"AddTabButtonRolloverBG Pressed"]);
                originals[name] = original = original ?: (id)[NSNull null];
            }
            if (original != [NSNull null]) return original;
        }
    }
    CGFloat scale;
    if ([name hasPrefix:@"AW "]) scale = 168.0 / 175.0;
    else if ([name hasPrefix:@"IW "]) scale = 216.0 / 223.0;
    else return image;
    static NSMutableDictionary *cache;
    @synchronized ([NSImage class]) {
        if (!cache) cache = [[NSMutableDictionary alloc] init];
        NSImage *darkened = cache[name];
        if (!darkened) cache[name] = darkened = SLDarkenedImage(image, scale);
        return darkened;
    }
}

static void SLHookTabArt(void)
{
    Method m = class_getClassMethod([NSImage class], @selector(imageNamed:));
    if (m) orig_imageNamed = (void *)method_setImplementation(m, (IMP)sl_imageNamed);
}

// ---- CUIDraw ----------------------------------------------------------------------------

static BOOL SLIsSnowLeopardWindowType(NSString *windowType)
{
    return !windowType || [windowType isEqualToString:@"regularwin"] || [windowType hasPrefix:@"utilwin"]
        || [windowType isEqualToString:@"kCUIWindowTypeTextured"];
}

static OSStatus sl_CUIDraw(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result)
{
    NSDictionary *o = (NSDictionary *)options;
    NSString *widget = [o isKindOfClass:[NSDictionary class]] ? o[@"widget"] : nil;
    if (!ctx || ![widget isKindOfClass:[NSString class]] || [o[@"kCUIMaskOnlyKey"] boolValue] || !SLIsSnowLeopardWindowType(o[@"windowtype"])
        || SLIsCustomRenderer(renderer))
        return orig_CUIDraw(renderer, rect, ctx, options, result);

    if ([widget hasPrefix:@"titlebar"]) {
        NSString *name = SLButtonImageName(o);
        if (name) {
            SLDrawButton(name, rect, ctx, [o[@"is.flipped"] boolValue]);
            return noErr;
        }
    } else if ([widget isEqualToString:@"kCUIWidgetWindowFrame"]) {
        OSStatus status = orig_CUIDraw(renderer, rect, ctx, options, result);
        if ([o[@"windowtype"] isEqualToString:@"kCUIWindowTypeTextured"]) SLDrawTexturedFrame(rect, ctx, o);
        else SLDrawTitleBar(rect, ctx, o);
        return status;
    } else if ([widget isEqualToString:@"kCUIWidgetWindowBottomBar"] && o[@"windowtype"]) {
        OSStatus status = orig_CUIDraw(renderer, rect, ctx, options, result);
        SLDrawBottomBar(rect, ctx, o);
        return status;
    } else if ([widget isEqualToString:@"kCUIWidgetToolbarBaselineSeparator"] && o[@"windowtype"]) {
        SLDrawToolbarSeparator(rect, ctx, o);
        return noErr;
    }
    return orig_CUIDraw(renderer, rect, ctx, options, result);
}

static id (*orig_appInit)(id, SEL);

static void SLSetUp(void)
{
    static BOOL done = NO;
    if (done) return;
    done = YES;
    SLHookFunctionFn hook = (SLHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    void *cuiDraw = dlsym(RTLD_DEFAULT, "CUIDraw");
    if (!hook || !cuiDraw) return;
    if (!SLLoadArt()) {
        NSLog(@"SnowLeopardWindows: SLWindowArt.bin missing or unreadable; leaving window chrome alone.");
        return;
    }
    SLHookAppearance();
    hook(cuiDraw, (void *)sl_CUIDraw, (void **)&orig_CUIDraw);
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

@implementation SLWindows

/* Nothing is set up until the process has its application object. MIP can
   load the plugin before that exists (AppKit's open/save panel service checks
   in with Launch Services and then waits for a client before creating NSApp
   and its window server connection); touching the window server in between
   breaks that service. So: with NSApp already there (normal applications,
   where MIP loads the plugin inside -[NSApplication init]), set up now;
   otherwise as soon as -[NSApplication init] returns. */
+ (void)load
{
    if (floor(NSAppKitVersionNumber) != 1265) return;     // Mavericks' AppKit only
    if (NSApp && [NSThread isMainThread]) {
        SLSetUp();
    } else {
        Method init = class_getInstanceMethod([NSApplication class], @selector(init));
        if (init) orig_appInit = (void *)method_setImplementation(init, (IMP)sl_appInit);
    }
}

@end
