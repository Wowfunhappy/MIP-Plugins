//
//  SLSkinned.m
//  Scroll bars that apps skin themselves for Lion's arrowless legacy scroll
//  bars: left alone, except in the apps handled here.
//
//  Some apps subclass NSScroller to draw their own track and thumb
//  (-drawKnobSlotInRect:highlight:, -drawKnob) for Lion's legacy scroll bars,
//  which have no arrows, and say so by overriding +isCompatibleWithOverlayScrollers
//  (Lion's API). Snow Leopard's layout doesn't suit such a skin, so these are
//  left exactly as the app draws them (pre-Lion skinned scrollers, which don't
//  override that, get 10.6's treatment as they did on 10.6; Safari's sidebar,
//  SidebarScroller, is one left alone) - except Reminders'
//  (RemindersLegacyScroller: a paper track, or leather in its sidebar, with a
//  slim black pill). Reminders themes itself (an NSAppearance of its own,
//  RemindersLeather.car), which would also leave it alone (SLScrollBars.m).
//
//  It gets Snow Leopard's layout and behaviour like any scroll bar, and
//  Reminders paints its track and thumb into that layout itself. The ends -
//  arrow buttons, and the cap at an end without arrows - are Snow Leopard's,
//  with Reminders' track fading into Snow Leopard's over a short stretch
//  before them, so it runs into the rounded end of the Aqua track instead of
//  stopping at it. The thumb is Reminders' pill, pulled in 3 points from each
//  end of its travel so it rests inside the rounded ends of the track, as
//  10.6's own thumb does (SLSkinnedDrawKnob).
//
//    On paper: the Snow Leopard art as it is.
//    On leather: the art, fade included, turned gray and darkened into the
//      leather's range, keeping its shading; its triangles then darkened
//      further, so the arrows read.
//

#import "SLScrollBars.h"
#import <mach-o/dyld.h>
#import <libkern/OSAtomic.h>
#import <pthread.h>

static Class gRemindersScroller;

static const CGFloat kSLSkinFade = 20;      // points of track over which the app's fades into Snow Leopard's

typedef enum { kSLSkinNone, kSLSkinRemindersPaper, kSLSkinRemindersLeather } SLSkin;

static SLSkin SLSkinOf(NSScroller *scroller)
{
    if (gRemindersScroller && [scroller isKindOfClass:gRemindersScroller]) {
        SEL sel = @selector(isDark);
        BOOL dark = [scroller respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(scroller, sel);
        return dark ? kSLSkinRemindersLeather : kSLSkinRemindersPaper;
    }
    return kSLSkinNone;
}

BOOL SLSkinHandled(NSScroller *scroller)
{
    return SLSkinOf(scroller) != kSLSkinNone;
}

// ProKit (Apple's framework for its pro apps: Aperture, Final Cut, Logic...)
// draws its scrollers itself - track, thumb and arrows, in its own art - and
// lays them out with AppKit's geometry, arrows included. Mavericks' AppKit has
// no arrows in legacy scroll bars, and apps made for Lion ask ProKit
// (-[NSApplication wantsScrollerTrackEndcaps]) for its arrowless style, with
// rounded ends to the track. With 10.6's geometry back, and that style off
// (-[NSProScroller _shouldDrawTrackEndcaps]), ProKit draws its arrows as it did
// on 10.6.
static Class gProScroller;
static BOOL (*orig_pro_shouldDrawTrackEndcaps)(id, SEL);

// Aperture's full-screen scroller (RKFullScreenBlackScroller, a ProKit
// scroller with its own black art) still has its 10.6 drawing: arrows
// (-drawArrow:highlight:), then track, with the cups the thumb rests in
// (-drawKnobSlot), then thumb. It chooses between that and its Lion drawing
// by asking +[RKGlobals isLionOrGreater] (and the scroller style), in
// -drawRect: and again in -drawKnobSlot: from Lion on, with legacy scroll
// bars, it draws no arrows, and rounds the track's ends with its endcap image
// where the cups were. With 10.6's scroll bars, -drawRect: runs with
// +isLionOrGreater answering NO - on the main thread, for that call only - so
// all of it takes its 10.6 path. Aperture no longer has the arrow art; it is
// in this plugin (ApertureArt/, from an Aperture that ran on 10.6),
// registered under the names the scroller loads it by (+[NSImage
// imageNamed:] in its +initialize).
static Class gApertureScroller;
static void (*orig_aperture_drawRect)(id, SEL, NSRect);
static BOOL (*orig_aperture_isLionOrGreater)(id, SEL);
static BOOL gApertureDrawing10_6;      // main thread only

static BOOL sl_aperture_isLionOrGreater(id self, SEL _cmd)
{
    if (gApertureDrawing10_6 && pthread_main_np()) return NO;
    return orig_aperture_isLionOrGreater(self, _cmd);
}

static void sl_aperture_drawRect(NSScroller *self, SEL _cmd, NSRect dirty)
{
    if (!(SLIsEnabled() && [self scrollerStyle] == NSScrollerStyleLegacy && pthread_main_np())) {
        orig_aperture_drawRect(self, _cmd, dirty);
        return;
    }
    // The Lion drawing flips the endcap and the bottom cups (-[NSImage
    // setFlipped:], on the shared images) to round the track's bottom end;
    // the 10.6 drawing expects them as they come.
    for (NSString *name in @[ @"FSscroll-Together-Endcap-N", @"FSscroll-Apart-BottomArrowA-N", @"FSscroll-Apart-BottomArrowA-P" ])
        [[NSImage imageNamed:name] setFlipped:NO];
    BOOL was = gApertureDrawing10_6;
    gApertureDrawing10_6 = YES;
    orig_aperture_drawRect(self, _cmd, dirty);
    gApertureDrawing10_6 = was;
}

static void SLApertureInstall(void)
{
    Class cls = objc_getClass("RKFullScreenBlackScroller"), globals = objc_getClass("RKGlobals");
    Method isLion = globals ? class_getClassMethod(globals, sel_registerName("isLionOrGreater")) : NULL;
    if (!cls || !isLion || strncmp(method_getTypeEncoding(isLion), "c", 1) != 0
        || !class_getInstanceMethod(cls, sel_registerName("drawArrow:highlight:"))
        || !class_getInstanceMethod(cls, sel_registerName("drawKnobSlot"))) return;
    // Named before anything messages the class, so its +initialize finds them.
    NSBundle *bundle = SLPluginBundle();
    NSArray *paths = [bundle pathsForResourcesOfType:@"tiff" inDirectory:@"ApertureArt"];
    if ([paths count] == 0) return;
    for (NSString *path in paths) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];     // kept: a named image lives as long as its name
        [image setName:[[path lastPathComponent] stringByDeletingPathExtension]];
    }
    orig_aperture_isLionOrGreater = (void *)method_setImplementation(isLion, (IMP)sl_aperture_isLionOrGreater);
    SLHook(cls, @selector(drawRect:), (IMP)sl_aperture_drawRect, (IMP *)&orig_aperture_drawRect);
    gApertureScroller = cls;
}

// A ProKit scroller - unless its class draws itself in its own -drawRect:,
// which is left alone like any app's own skin (Aperture's full-screen
// scroller is drawn as on 10.6, above).
BOOL SLProKitScroller(NSScroller *scroller)
{
    if (!gProScroller || ![scroller isKindOfClass:gProScroller]) return NO;
    if (gApertureScroller && [scroller isKindOfClass:gApertureScroller]) return YES;
    return class_getMethodImplementation(object_getClass(scroller), @selector(drawRect:))
        == class_getMethodImplementation(gProScroller, @selector(drawRect:));
}

static BOOL sl_pro_shouldDrawTrackEndcaps(NSScroller *self, SEL _cmd)
{
    if (SLIsEnabled() && [self scrollerStyle] == NSScrollerStyleLegacy) return NO;
    return orig_pro_shouldDrawTrackEndcaps(self, _cmd);
}

// ProKit may be loaded after the plugin (it's a framework in the app), so this
// is tried again when images load.
static void SLProKitInstall(void)
{
    if (gProScroller) return;
    Class cls = NSClassFromString(@"NSProScroller");
    const char *image = cls ? class_getImageName(cls) : NULL;
    if (!image || !strstr(image, "/ProKit.framework/") || ![cls isSubclassOfClass:[NSScroller class]]) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("_shouldDrawTrackEndcaps"));
    if (!m || strncmp(method_getTypeEncoding(m), "c", 1) != 0) return;
    orig_pro_shouldDrawTrackEndcaps = (void *)method_setImplementation(m, (IMP)sl_pro_shouldDrawTrackEndcaps);
    gProScroller = cls;
}

static void SLImageAdded(const struct mach_header *header, intptr_t slide)
{
    SLProKitInstall();
}

static BOOL SLOverrides(Class cls, Class base, SEL sel, BOOL classMethod)
{
    Method mine = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    Method theirs = classMethod ? class_getClassMethod(base, sel) : class_getInstanceMethod(base, sel);
    return mine && theirs && method_getImplementation(mine) != method_getImplementation(theirs);
}

BOOL SLLionSkin(NSScroller *scroller)
{
    static CFMutableDictionaryRef verdicts;         // class -> kCFBooleanTrue / False
    static OSSpinLock lock = OS_SPINLOCK_INIT;
    Class cls = object_getClass(scroller);
    if (cls == [NSScroller class]) return NO;
    OSSpinLockLock(&lock);
    if (!verdicts) verdicts = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    CFBooleanRef verdict = CFDictionaryGetValue(verdicts, cls);
    OSSpinLockUnlock(&lock);
    if (verdict) return verdict == kCFBooleanTrue;

    const char *image = class_getImageName(cls);
    BOOL skinned = !(image && strstr(image, "/AppKit.framework/"))
        && SLOverrides(cls, [NSScroller class], @selector(drawKnobSlotInRect:highlight:), NO)
        && SLOverrides(cls, [NSScroller class], @selector(isCompatibleWithOverlayScrollers), YES);
    OSSpinLockLock(&lock);
    CFDictionarySetValue(verdicts, cls, skinned ? kCFBooleanTrue : kCFBooleanFalse);
    OSSpinLockUnlock(&lock);
    return skinned;
}

static void SLFillWithBlend(CGContextRef ctx, CGRect rect, CGBlendMode mode, CGFloat gray)
{
    CGContextSetBlendMode(ctx, mode);
    CGContextSetGrayFillColor(ctx, gray, 1);
    CGContextFillRect(ctx, rect);
}

// Paints `paint` (Snow Leopard art) into `rect`, turned gray and mapped into
// the skin's grays (out = in * scale + offset), or as it is.
static void SLSkinPaint(NSScroller *scroller, CGRect rect, void (^paint)(void))
{
    CGFloat scale, offset;
    switch (SLSkinOf(scroller)) {
        case kSLSkinRemindersLeather: scale = 0.22; offset = 0.02; break;      // buttons of 232 become 56
        default: paint(); return;
    }
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextBeginTransparencyLayerWithRect(ctx, rect, NULL);
    paint();
    SLFillWithBlend(ctx, rect, kCGBlendModeColor, 0.5);             // gray
    SLFillWithBlend(ctx, rect, kCGBlendModeMultiply, scale);
    SLFillWithBlend(ctx, rect, kCGBlendModePlusLighter, offset);
    // Back to the art's own shape.
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
    paint();
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// In the dark scroll bar the triangles are darkened further (to about 6, from
// about 24, on buttons of about 58), so the dark-on-dark arrows read: each
// pixel towards black in proportion to how much of it the triangle covers, so
// the shape and antialiasing are unchanged. The triangles are found in the
// Snow Leopard art itself, rendered at the context's scale: they are its
// darkest pixels (gray 69, 12 when pressed, on buttons of 232, or 130-150
// when pressed; the faded triangles of an inactive window, 138, are left).
static void SLRemindersDarkenTriangles(const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart, CGRect rect)
{
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    CGSize device = CGContextConvertSizeToDeviceSpace(ctx, CGSizeMake(1, 1));
    int scale = MAX(1, (int)lround(fabs(device.height)));
    size_t w = (size_t)ceil(rect.size.width * scale), h = (size_t)ceil(rect.size.height * scale);
    if (w == 0 || h == 0 || w > 256 || h > 256) return;

    // The art, in gray, laid out as in the view (row 0 at the top).
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef g = CGBitmapContextCreate(NULL, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!g) return;
    CGContextSetGrayFillColor(g, 1, 1);
    CGContextFillRect(g, CGRectMake(0, 0, w, h));
    if (st->flipped) { CGContextTranslateCTM(g, 0, h); CGContextScaleCTM(g, 1, -1); }
    CGContextScaleCTM(g, scale, scale);
    CGContextTranslateCTM(g, -rect.origin.x, -rect.origin.y);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:g flipped:st->flipped]];
    SLPaintArrow(st, arrow, highlightPart);
    [NSGraphicsContext restoreGraphicsState];

    // Triangle coverage, as black over the triangle (premultiplied: alpha only).
    const uint8_t *v = CGBitmapContextGetData(g);
    uint8_t *out = calloc(w * h * 4, 1);
    for (size_t i = 0; i < w * h; i++)
        out[i * 4 + 3] = (uint8_t)lroundf(fmaxf(0, fminf(1, (130.0f - v[i]) / 61.0f)) * 255);
    CGContextRelease(g);

    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef o = CGBitmapContextCreate(out, w, h, 8, w * 4, rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(rgb);
    CGImageRef image = o ? CGBitmapContextCreateImage(o) : NULL;
    if (o) CGContextRelease(o);
    free(out);
    if (!image) return;
    CGContextSaveGState(ctx);
    if (st->flipped) {
        CGContextTranslateCTM(ctx, 0, CGRectGetMinY(rect) + CGRectGetMaxY(rect));
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextDrawImage(ctx, rect, image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
}

// Stands in for Reminders' -drawKnob: its pill (its own images, normal or
// rollover, centred as it centres them), but pulled in from the ends of the
// knob's travel. 10.6's thumb is as wide as the track and its round end fills
// the rounded end of the track at each end of its travel, covering the
// track's rim there; Reminders' narrow pill, drawn over the same length, put
// its tip on that rim.
void SLSkinnedDrawKnob(NSScroller *scroller, const SLState *st)
{
    NSRect rect = SLDrawingRect(st, NSScrollerKnob);
    if (NSIsEmptyRect(rect)) return;
    id imp = [scroller respondsToSelector:@selector(scrollerImp)] ? [scroller performSelector:@selector(scrollerImp)] : nil;
    BOOL rollover = [imp respondsToSelector:@selector(shouldDrawRolloverState)] && ((BOOL (*)(id, SEL))objc_msgSend)(imp, @selector(shouldDrawRolloverState));
    NSImage *top = [scroller performSelector:rollover ? @selector(knobTopRollover) : @selector(knobTop)];
    NSImage *mid = [scroller performSelector:rollover ? @selector(knobMidRollover) : @selector(knobMid)];
    NSImage *bot = [scroller performSelector:rollover ? @selector(knobBotRollover) : @selector(knobBot)];
    if (!top || !mid || !bot) return;
    CGFloat width = [mid size].width;
    // As -drawKnob: centred, then a point right in the light scroll bar.
    rect.origin.x += floor((rect.size.width - width) * 0.5) + (SLSkinOf(scroller) == kSLSkinRemindersLeather ? 0 : 1);
    rect.size.width = width;
    rect = NSInsetRect(rect, 0, 3);       // its tip rests inside the rounded end, clear of the rim
    NSDrawThreePartImage(rect, top, mid, bot, YES, NSCompositeSourceOver, 1, NO);
}

// Stands in for -[NSScroller drawArrow:highlightPart:] (SLPaintArrow): one end
// of the scroll bar.
void SLSkinnedPaintArrow(NSScroller *scroller, const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart)
{
    NSRect end = SLDrawingRect(st, arrow == NSScrollerDecrementArrow ? NSScrollerDecrementLine : NSScrollerIncrementLine);
    if (NSIsEmptyRect(end)) return;
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    BOOL nearEnd = (arrow == NSScrollerDecrementArrow);

    // The stretch of track next to this end, where the app's track gives way
    // to Snow Leopard's: Snow Leopard's track drawn over it, from transparent
    // on the far side to opaque where the end's art begins.
    NSRect slot = SLDrawingRect(st, NSScrollerKnobSlot);
    CGFloat slotMin = st->horizontal ? NSMinX(slot) : NSMinY(slot), slotMax = st->horizontal ? NSMaxX(slot) : NSMaxY(slot);
    CGFloat edge = nearEnd ? (st->horizontal ? NSMaxX(end) : NSMaxY(end)) : (st->horizontal ? NSMinX(end) : NSMinY(end));
    CGFloat from = nearEnd ? MIN(edge + kSLSkinFade, slotMax) : MAX(edge - kSLSkinFade, slotMin);
    CGFloat lo = MIN(from, edge), hi = MAX(from, edge);
    if (hi - lo >= 1) {
        NSRect fade = st->horizontal ? NSMakeRect(lo, NSMinY(slot), hi - lo, NSHeight(slot)) : NSMakeRect(NSMinX(slot), lo, NSWidth(slot), hi - lo);
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, NSRectToCGRect(fade));
        CGContextBeginTransparencyLayerWithRect(ctx, NSRectToCGRect(fade), NULL);
        SLSkinPaint(scroller, NSRectToCGRect(fade), ^{ SLPaintSlot(st, slot); });
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGGradientRef gradient = CGGradientCreateWithColorComponents(gray, (CGFloat[]){ 0, 0, 0, 1 }, NULL, 2);   // alpha 0 -> 1
        CGColorSpaceRelease(gray);
        CGPoint p0 = st->horizontal ? CGPointMake(from, 0) : CGPointMake(0, from);
        CGPoint p1 = st->horizontal ? CGPointMake(edge, 0) : CGPointMake(0, edge);
        CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
        CGContextDrawLinearGradient(ctx, gradient, p0, p1, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(gradient);
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
    }

    // Snow Leopard's own end: arrows, or the cap.
    SLSkinPaint(scroller, NSRectToCGRect(end), ^{ SLPaintArrow(st, arrow, highlightPart); });
    if (SLSkinOf(scroller) == kSLSkinRemindersLeather)
        SLRemindersDarkenTriangles(st, arrow, highlightPart, NSRectToCGRect(end));
}

void SLSkinnedInstall(void)
{
    SLProKitInstall();
    if (!gProScroller) _dyld_register_func_for_add_image(SLImageAdded);
    NSString *app = [[NSBundle mainBundle] bundleIdentifier];
    Class cls;
    if ([app isEqualToString:@"com.apple.Aperture"]) SLApertureInstall();
    if ([app isEqualToString:@"com.apple.reminders"] && (cls = NSClassFromString(@"RemindersLegacyScroller")) && [cls isSubclassOfClass:[NSScroller class]])
        gRemindersScroller = cls;
}
