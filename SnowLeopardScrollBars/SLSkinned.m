//
//  SLSkinned.m
//  Scroll bars that apps skin themselves, drawn for Lion's arrowless legacy
//  scroll bars, as if they had been made for Snow Leopard.
//
//  Some apps subclass NSScroller to draw their own track and thumb
//  (-drawKnobSlotInRect:highlight:, -drawKnob) for Lion's legacy scroll bars,
//  which have no arrows, and say so by overriding +isCompatibleWithOverlayScrollers
//  (Lion's API): Safari's sidebar (SidebarScroller: a translucent track and a
//  light pill), Reminders (RemindersLegacyScroller: paper, or leather in its
//  sidebar). Pre-Lion skinned scrollers don't override that, and get 10.6's
//  treatment unchanged, arrows and all, as they did on 10.6.
//
//  These get Snow Leopard's layout and behaviour like any scroll bar, and the
//  app paints its track and thumb into that layout itself. The ends - arrow
//  buttons, and the cap at an end without arrows - are Snow Leopard's, with
//  the app's track fading into Snow Leopard's over a short stretch before
//  them, so it runs into the rounded end of the Aqua track instead of stopping
//  at it. Their tracks may be translucent, so they are not opaque.
//
//  Reminders themes itself (an NSAppearance of its own, RemindersLeather.car),
//  so its scroll bars would otherwise be left alone (SLScrollBars.m); they are
//  taken on here. In its dark sidebar the Snow Leopard art, fade included, is
//  turned gray and darkened into the leather's range, keeping its shading; its
//  triangles are then darkened further, so the arrows read.
//

#import "SLScrollBars.h"
#import <libkern/OSAtomic.h>

static Class gRemindersScroller;

static const CGFloat kSLSkinFade = 20;      // points of track over which the app's fades into Snow Leopard's

BOOL SLRemindersScroller(NSScroller *scroller)
{
    return gRemindersScroller && [scroller isKindOfClass:gRemindersScroller];
}

static BOOL SLOverrides(Class cls, Class base, SEL sel, BOOL classMethod)
{
    Method mine = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    Method theirs = classMethod ? class_getClassMethod(base, sel) : class_getInstanceMethod(base, sel);
    return mine && theirs && method_getImplementation(mine) != method_getImplementation(theirs);
}

BOOL SLSkinnedScroller(NSScroller *scroller)
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

static BOOL SLSkinIsDark(NSScroller *scroller)
{
    SEL sel = @selector(isDark);
    return SLRemindersScroller(scroller) && [scroller respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(scroller, sel);
}

static void SLFillWithBlend(CGContextRef ctx, CGRect rect, CGBlendMode mode, CGFloat gray)
{
    CGContextSetBlendMode(ctx, mode);
    CGContextSetGrayFillColor(ctx, gray, 1);
    CGContextFillRect(ctx, rect);
}

// Paints `paint` (Snow Leopard art) into `rect`; in the dark scroll bar,
// turned gray and mapped into the leather's range.
static void SLSkinPaint(NSScroller *scroller, CGRect rect, void (^paint)(void))
{
    if (!SLSkinIsDark(scroller)) { paint(); return; }
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextBeginTransparencyLayerWithRect(ctx, rect, NULL);
    paint();
    SLFillWithBlend(ctx, rect, kCGBlendModeColor, 0.5);             // gray
    SLFillWithBlend(ctx, rect, kCGBlendModeMultiply, 0.22);         // into the leather's range:
    SLFillWithBlend(ctx, rect, kCGBlendModePlusLighter, 0.02);      // buttons of 232 become 56
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
    if (SLSkinIsDark(scroller))
        SLRemindersDarkenTriangles(st, arrow, highlightPart, NSRectToCGRect(end));
}

void SLSkinnedInstall(void)
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.reminders"]) return;
    Class cls = NSClassFromString(@"RemindersLegacyScroller");
    if (cls && [cls isSubclassOfClass:[NSScroller class]]) gRemindersScroller = cls;
}
