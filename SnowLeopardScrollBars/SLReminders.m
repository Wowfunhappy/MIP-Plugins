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
//  Apple's own skinned scroll bars of the Snow Leopard era (iTunes 10,
//  iPhoto '11, Aperture 3) kept the system's layout and its arrows, placed as
//  set in Appearance preferences, and drew the arrow buttons in the skin's own
//  style. So here: Snow Leopard's layout and behaviour as for any scroll bar;
//  Reminders paints its track and thumb into that layout itself; and the arrow
//  buttons are drawn in Reminders' style - its own track behind them, a hairline
//  between buttons and track, and triangles in the thumb's translucent black.
//

#import "SLScrollBars.h"

static Class gRemindersScroller;

BOOL SLRemindersSkinned(NSScroller *scroller)
{
    return gRemindersScroller && [scroller isKindOfClass:gRemindersScroller];
}

static BOOL SLRemindersIsDark(NSScroller *scroller)
{
    SEL sel = @selector(isDark);
    return [scroller respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(scroller, sel);
}

// One arrow button: `rect` along the axis, its triangle pointing to the near
// (decrement) or far end; `separator` is the edge facing the slot or the other
// button, given as the along-axis coordinate of the hairline.
static void SLRemindersPaintButton(const SLState *st, NSRect rect, BOOL decrement, BOOL pressed, BOOL dark, CGFloat separator)
{
    // Pressed: the button darkens, as the thumb's black over the track.
    if (pressed) {
        [[NSColor colorWithCalibratedWhite:0 alpha:dark ? 0.30 : 0.10] set];
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
    }

    // The hairline between this button and what lies towards the slot.
    [[NSColor colorWithCalibratedWhite:0 alpha:dark ? 0.45 : 0.13] set];
    if (st->horizontal) NSRectFillUsingOperation(NSMakeRect(separator, NSMinY(rect), 1, NSHeight(rect)), NSCompositeSourceOver);
    else NSRectFillUsingOperation(NSMakeRect(NSMinX(rect), separator, NSWidth(rect), 1), NSCompositeSourceOver);

    // The triangle: as wide as the thumb (8 points) and 4 deep, centred on the
    // thumb's line - Reminders' -drawKnob puts the thumb's middle 8 points in
    // from the scroll bar's edge, or 7 in the dark scroll bar - in the thumb's
    // black (a little stronger, as it is much smaller); fainter in an inactive
    // window.
    CGFloat alpha = dark ? 0.75 : 0.45;
    if (pressed) alpha = MIN(1, alpha + 0.2);
    if (!st->arrowsActive) alpha *= 0.55;
    CGFloat width = st->small ? 6 : 8, depth = st->small ? 3 : 4;
    CGFloat across = (st->horizontal ? NSMinY(rect) : NSMinX(rect)) + (st->small ? 6 : 8) - (dark ? 1 : 0);
    CGFloat base = round((st->horizontal ? NSMidX(rect) : NSMidY(rect)) + (decrement ? depth : -depth) / 2);
    CGFloat tip = base + (decrement ? -depth : depth);
    NSBezierPath *path = [NSBezierPath bezierPath];
    if (st->horizontal) {
        [path moveToPoint:NSMakePoint(base, across - width / 2)];
        [path lineToPoint:NSMakePoint(base, across + width / 2)];
        [path lineToPoint:NSMakePoint(tip, across)];
    } else {
        [path moveToPoint:NSMakePoint(across - width / 2, base)];
        [path lineToPoint:NSMakePoint(across + width / 2, base)];
        [path lineToPoint:NSMakePoint(across, tip)];
    }
    [path closePath];
    [[NSColor colorWithCalibratedWhite:0 alpha:alpha] set];
    [path fill];
}

// Stands in for -[NSScroller drawArrow:highlightPart:] (SLPaintArrow): one end
// of the scroll bar, with whatever buttons it has.
void SLRemindersPaintArrow(NSScroller *scroller, const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart)
{
    NSRect end = SLDrawingRect(st, arrow == NSScrollerDecrementArrow ? NSScrollerDecrementLine : NSScrollerIncrementLine);
    if (NSIsEmptyRect(end)) return;

    // Reminders' own track under the whole end.
    [scroller drawKnobSlotInRect:end highlight:NO];
    if (st->config == 0) return;

    BOOL dark = SLRemindersIsDark(scroller);
    BOOL nearEnd = (arrow == NSScrollerDecrementArrow);
    CGFloat endMin = st->horizontal ? NSMinX(end) : NSMinY(end);
    CGFloat endMax = st->horizontal ? NSMaxX(end) : NSMaxY(end);

    // The buttons are the arrows' click areas (parts 7 and 8 are DoubleBoth's
    // second pair); those in this end are drawn here.
    static const NSScrollerPart parts[4] = { NSScrollerDecrementLine, NSScrollerIncrementLine, 7, 8 };
    for (int i = 0; i < 4; i++) {
        NSRect button = SLHitRect(st, parts[i]);
        if (NSIsEmptyRect(button)) continue;
        CGFloat bMin = st->horizontal ? NSMinX(button) : NSMinY(button);
        CGFloat bMax = st->horizontal ? NSMaxX(button) : NSMaxY(button);
        if (bMin < endMin - 0.5 || bMax > endMax + 0.5) continue;

        BOOL decrement = (parts[i] == NSScrollerDecrementLine || parts[i] == 7);
        // Which button is lit: the pressed arrow, in the pair it was pressed in.
        BOOL pressed = st->arrowsActive && highlightPart != -1 &&
                       highlightPart == (decrement ? NSScrollerDecrementArrow : NSScrollerIncrementArrow);
        // The hairline goes on the side facing the middle of the scroll bar,
        // which for the inner button of a pair is also the one between them.
        CGFloat separator = nearEnd ? bMax - 1 : bMin;
        SLRemindersPaintButton(st, button, decrement, pressed, dark, separator);
    }
}

void SLRemindersInstall(void)
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.reminders"]) return;
    Class cls = NSClassFromString(@"RemindersLegacyScroller");
    if (!cls || ![cls isSubclassOfClass:[NSScroller class]] ||
        ![cls instancesRespondToSelector:@selector(drawKnobSlotInRect:highlight:)]) return;
    gRemindersScroller = cls;
}
