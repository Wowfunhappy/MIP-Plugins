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
//  override that, get 10.6's treatment as they did on 10.6) - except:
//
//    Reminders (RemindersLegacyScroller: a paper track, or leather in its
//    sidebar, with a slim black pill). Reminders themes itself (an
//    NSAppearance of its own, RemindersLeather.car), which would also leave
//    it alone (SLScrollBars.m).
//    Safari's sidebar (SidebarScroller: a translucent track and a light pill).
//
//  These get Snow Leopard's layout and behaviour like any scroll bar, and the
//  app paints its track and thumb into that layout itself. The ends - arrow buttons, and
//  the cap at an end without arrows - are Snow Leopard's, with the app's track
//  fading into Snow Leopard's over a short stretch before them, so it runs
//  into the rounded end of the Aqua track instead of stopping at it. Their
//  tracks may be translucent, so they are not opaque. Per skin:
//
//    Reminders' paper: the Snow Leopard art as it is.
//    Reminders' leather: the art, fade included, turned gray and darkened into
//      the leather's range, keeping its shading; its triangles then darkened
//      further, so the arrows read.
//    Safari's sidebar: the art turned gray and mapped into the sidebar's grays
//      (buttons of 232 become about 152, just under its 160 thumb; triangles
//      of 69 about 70), and Safari's thumb.
//

#import "SLScrollBars.h"
#import <libkern/OSAtomic.h>

static Class gRemindersScroller, gSafariSidebarScroller;

static const CGFloat kSLSkinFade = 20;      // points of track over which the app's fades into Snow Leopard's

typedef enum { kSLSkinNone, kSLSkinRemindersPaper, kSLSkinRemindersLeather, kSLSkinSafariSidebar } SLSkin;

static SLSkin SLSkinOf(NSScroller *scroller)
{
    if (gSafariSidebarScroller && [scroller isKindOfClass:gSafariSidebarScroller]) return kSLSkinSafariSidebar;
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
        case kSLSkinSafariSidebar:    scale = 0.50; offset = 0.14; break;      // 232 -> 152, 69 -> 70
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
    NSString *app = [[NSBundle mainBundle] bundleIdentifier];
    Class cls;
    if ([app isEqualToString:@"com.apple.reminders"] && (cls = NSClassFromString(@"RemindersLegacyScroller")) && [cls isSubclassOfClass:[NSScroller class]])
        gRemindersScroller = cls;
    if ([app isEqualToString:@"com.apple.Safari"] && (cls = NSClassFromString(@"SidebarScroller")) && [cls isSubclassOfClass:[NSScroller class]])
        gSafariSidebarScroller = cls;
}
