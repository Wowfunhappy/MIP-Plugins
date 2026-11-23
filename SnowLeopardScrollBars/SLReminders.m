//
//  SLReminders.m
//  Reminders' scroll bars, as if it had been made for Snow Leopard.
//
//  Reminders themes itself (an NSAppearance of its own, RemindersLeather.car),
//  so its scroll bars would normally be left alone. They are skinned by
//  RemindersLegacyScroller: a flat track (paper, or leather in the sidebar;
//  -trackImage, painted by -drawKnobSlotInRect:highlight:) and a slim
//  translucent black pill of a thumb (-drawKnob, painted into
//  -rectForPart:NSScrollerKnob). It was drawn for Lion's arrowless legacy
//  scroll bars and has no arrows.
//
//  Here it gets Snow Leopard's layout and behaviour like any scroll bar, and
//  Reminders paints its track and thumb into that layout itself. The ends -
//  arrow buttons, and the cap at an end without arrows - are Snow Leopard's,
//  with Reminders' track fading into Snow Leopard's over a short stretch
//  before them, so it runs into the rounded end of the Aqua track instead of
//  stopping at it. In the dark sidebar the same Snow Leopard art, fade
//  included, is turned gray and darkened into the leather's range, keeping
//  its shading; its triangles are then darkened further, so the arrows read.
//

#import "SLScrollBars.h"

static Class gRemindersScroller;

static const CGFloat kSLRemindersFade = 20;     // points of track over which Reminders' fades into Snow Leopard's

BOOL SLRemindersSkinned(NSScroller *scroller)
{
    return gRemindersScroller && [scroller isKindOfClass:gRemindersScroller];
}

static BOOL SLRemindersIsDark(NSScroller *scroller)
{
    SEL sel = @selector(isDark);
    return [scroller respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(scroller, sel);
}

static void SLFillWithBlend(CGContextRef ctx, CGRect rect, CGBlendMode mode, CGFloat gray)
{
    CGContextSetBlendMode(ctx, mode);
    CGContextSetGrayFillColor(ctx, gray, 1);
    CGContextFillRect(ctx, rect);
}

// Paints `paint` (Snow Leopard art) into `rect`; in the dark scroll bar,
// turned gray and mapped into the leather's range.
static void SLRemindersPaint(NSScroller *scroller, CGRect rect, void (^paint)(void))
{
    if (!SLRemindersIsDark(scroller)) { paint(); return; }
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
void SLRemindersPaintArrow(NSScroller *scroller, const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart)
{
    NSRect end = SLDrawingRect(st, arrow == NSScrollerDecrementArrow ? NSScrollerDecrementLine : NSScrollerIncrementLine);
    if (NSIsEmptyRect(end)) return;
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    BOOL nearEnd = (arrow == NSScrollerDecrementArrow);

    // The stretch of track next to this end, where Reminders' track gives way
    // to Snow Leopard's: Snow Leopard's track drawn over it, from transparent
    // on the far side to opaque where the end's art begins.
    NSRect slot = SLDrawingRect(st, NSScrollerKnobSlot);
    CGFloat slotMin = st->horizontal ? NSMinX(slot) : NSMinY(slot), slotMax = st->horizontal ? NSMaxX(slot) : NSMaxY(slot);
    CGFloat edge = nearEnd ? (st->horizontal ? NSMaxX(end) : NSMaxY(end)) : (st->horizontal ? NSMinX(end) : NSMinY(end));
    CGFloat from = nearEnd ? MIN(edge + kSLRemindersFade, slotMax) : MAX(edge - kSLRemindersFade, slotMin);
    CGFloat lo = MIN(from, edge), hi = MAX(from, edge);
    if (hi - lo >= 1) {
        NSRect fade = st->horizontal ? NSMakeRect(lo, NSMinY(slot), hi - lo, NSHeight(slot)) : NSMakeRect(NSMinX(slot), lo, NSWidth(slot), hi - lo);
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, NSRectToCGRect(fade));
        CGContextBeginTransparencyLayerWithRect(ctx, NSRectToCGRect(fade), NULL);
        SLRemindersPaint(scroller, NSRectToCGRect(fade), ^{ SLPaintSlot(st, slot); });
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
    SLRemindersPaint(scroller, NSRectToCGRect(end), ^{ SLPaintArrow(st, arrow, highlightPart); });
    if (SLRemindersIsDark(scroller))
        SLRemindersDarkenTriangles(st, arrow, highlightPart, NSRectToCGRect(end));
}

void SLRemindersInstall(void)
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.reminders"]) return;
    Class cls = NSClassFromString(@"RemindersLegacyScroller");
    if (!cls || ![cls isSubclassOfClass:[NSScroller class]] ||
        ![cls instancesRespondToSelector:@selector(drawKnobSlotInRect:highlight:)]) return;
    gRemindersScroller = cls;
}
