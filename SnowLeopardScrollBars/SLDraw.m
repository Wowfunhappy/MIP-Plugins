//
//  SLDraw.m
//  Snow Leopard scroll bar geometry and painting.
//
//  Everything here works from an SLState, so the same code serves NSScroller
//  (SLScrollBars.m) and WebKit's NSScrollerImp-based scrollbars (SLWebKit.m).
//  The geometry is a port of AppKit 1038.29 (Mac OS X 10.6.3):
//
//      -[NSScroller checkSpaceForParts]            usable parts
//      -[NSScroller _drawingRectForPart:]          drawing rectangles
//      -[NSScroller rectForPart:]                  hit rectangles
//      -[NSScroller testPart:] / _PointInArrow     hit testing
//      -[NSScroller _old_drawKnob]                 thumb, with moving stripes
//      -[NSScroller _old_drawKnobSlotInRect:highlight:]
//      -[NSScroller _old_drawArrow:highlightPart:]
//

#import "SLScrollBars.h"

// ___NSTigerThemeArrowsLengths / ___NSTigerThemeArrowsInset: [size][config].
static const CGFloat kArrowsLengths[2][5] = { { 18, 28, 44, 44, 44 }, { 14, 21, 34, 34, 34 } };
static const CGFloat kArrowsInset[2][5]   = { {  4, 14, 30, 30, 30 }, {  3, 10, 23, 23, 23 } };

// A rectangle `length` long starting at `start` along the scroller's axis,
// hugging the far (max) side across it - where 10.6 always puts the parts.
static inline NSRect SLAlongRect(const SLState *st, CGFloat start, CGFloat length)
{
    if (st->horizontal)
        return NSMakeRect(start, NSMaxY(st->bounds) - st->thickness, length, st->thickness);
    return NSMakeRect(NSMaxX(st->bounds) - st->thickness, start, st->thickness, length);
}

static inline CGFloat SLMaxAlong(const SLState *st)
{
    return st->horizontal ? NSMaxX(st->bounds) : NSMaxY(st->bounds);
}

static inline CGFloat SLLength(const SLState *st)
{
    return st->horizontal ? st->bounds.size.width : st->bounds.size.height;
}

// 10.6 nudges values that are within 1/8 of an integer onto that integer
// before flooring/rounding (resolution-independence slop).
static inline CGFloat SLSnap(CGFloat v)
{
    CGFloat r = round(v);
    return (fabs(v - r) < 0.125) ? r : v;
}

static inline CGFloat SLMinimumKnob(const SLState *st)
{
    return st->small ? 20 : 26;
}

CGFloat SLMinimumKnobLength(BOOL small)
{
    return small ? 20 : 26;
}

// -[NSScroller checkSpaceForParts]
NSUsableScrollerParts SLUsableParts(const SLState *st)
{
    if (!st->enabled) return NSNoScrollerParts;

    CGFloat length = SLLength(st);
    if (st->fullLengthSlot) {
        // No arrows in this scroller's model (WebKit without arrow support):
        // there is a knob whenever it fits.
        return (length >= SLMinimumKnob(st)) ? NSAllScrollerParts : NSNoScrollerParts;
    }

    int s = st->small ? 1 : 0;
    BOOL together = (st->config == kSLArrowsDoubleMin || st->config == kSLArrowsDoubleMax);

    CGFloat needed = together ? kArrowsLengths[s][0] + kArrowsLengths[s][3] : 2 * kArrowsLengths[s][st->config];
    needed -= st->small ? 4 : 6;
    if (needed > length) return NSNoScrollerParts;

    needed = together ? kArrowsInset[s][0] + kArrowsInset[s][3] : 2 * kArrowsInset[s][st->config];
    needed += st->small ? 21 : 27;
    return (needed > length) ? NSOnlyScrollerArrows : NSAllScrollerParts;
}

// The stretch of the scroller the knob travels in: [start, start+length).
void SLSlotSpan(const SLState *st, CGFloat *start, CGFloat *length)
{
    int s = st->small ? 1 : 0;
    CGFloat a = st->horizontal ? st->bounds.origin.x : st->bounds.origin.y;
    CGFloat l = SLLength(st);

    if (st->fullLengthSlot) {
        // leave the whole length
    } else if (st->config == kSLArrowsDoubleMax) {
        a += kArrowsInset[s][0];
        l -= kArrowsInset[s][0] + kArrowsInset[s][3];
    } else if (st->config == kSLArrowsDoubleMin) {
        a += kArrowsInset[s][2];
        l -= kArrowsInset[s][0] + kArrowsInset[s][2];
    } else {
        a += kArrowsInset[s][st->config];
        l -= 2 * kArrowsInset[s][st->config];
    }
    *start = a;
    *length = l;
}

// Knob length and offset within the slot.
static void SLKnobMetrics(const SLState *st, CGFloat slotLength, CGFloat *knobLength, CGFloat *knobOffset)
{
    if (st->webKitMetrics) {
        // WebCore's ScrollbarThemeComposite::thumbLength / thumbPosition, so
        // the knob is drawn exactly where WebKit hit-tests and drags it.
        CGFloat knob = round(st->proportion * slotLength);
        if (knob < SLMinimumKnob(st)) knob = SLMinimumKnob(st);
        if (knob > slotLength) knob = 0;
        CGFloat position = (float)(st->value * (slotLength - knob));
        if (position > 0 && position < 1) position = 1;
        *knobLength = knob;
        *knobOffset = (int)position;
        return;
    }
    // The _knobSize computation in -_drawingRectForPart:.
    CGFloat knob = floor(SLSnap(slotLength * st->proportion));
    if (knob < SLMinimumKnob(st)) knob = SLMinimumKnob(st);
    *knobLength = knob;
    *knobOffset = round(SLSnap((slotLength - knob) * st->value));
}

// -[NSScroller _drawingRectForPart:]
NSRect SLDrawingRect(const SLState *st, NSScrollerPart part)
{
    NSUsableScrollerParts usable = SLUsableParts(st);
    int s = st->small ? 1 : 0;

    if (part != NSScrollerKnobSlot) {
        if (usable == NSNoScrollerParts) return NSZeroRect;
        if (usable == NSOnlyScrollerArrows && part != NSScrollerDecrementLine && part != NSScrollerIncrementLine)
            return NSZeroRect;
    }

    switch ((int)part) {
        case NSScrollerDecrementLine: {
            if (st->fullLengthSlot) return NSZeroRect;
            // With the arrows together at the far end, the near end only has a cap.
            int c = (st->config == kSLArrowsDoubleMax) ? 0 : st->config;
            return SLAlongRect(st, 0, kArrowsLengths[s][c]);
        }
        case NSScrollerIncrementLine: {
            if (st->fullLengthSlot) return NSZeroRect;
            int c = (st->config == kSLArrowsDoubleMin) ? 0 : st->config;
            CGFloat length = kArrowsLengths[s][c];
            return SLAlongRect(st, SLMaxAlong(st) - length, length);
        }
        case NSScrollerKnobSlot: {
            CGFloat start = st->horizontal ? st->bounds.origin.x : st->bounds.origin.y;
            CGFloat length = SLLength(st);
            if (st->enabled && usable != NSNoScrollerParts) SLSlotSpan(st, &start, &length);
            return SLAlongRect(st, start, length);
        }
        case NSScrollerDecrementPage:
        case NSScrollerKnob:
        case NSScrollerIncrementPage: {
            CGFloat start, length, knob, offset;
            SLSlotSpan(st, &start, &length);
            SLKnobMetrics(st, length, &knob, &offset);
            if (part == NSScrollerKnob && knob <= 0) return NSZeroRect;
            if (part == NSScrollerDecrementPage) return SLAlongRect(st, start, offset);
            if (part == NSScrollerKnob) return SLAlongRect(st, start + offset, knob);
            return SLAlongRect(st, start + offset + knob, length - (knob + offset));
        }
        default:
            return st->bounds;
    }
}

// -[NSScroller rectForPart:]: for the arrows this is the rectangle that
// reacts to clicks, which is smaller than the art. Parts 7 and 8 are the
// second pair of arrows with DoubleBoth (decrement at the far end, increment
// at the near end).
NSRect SLHitRect(const SLState *st, NSScrollerPart part)
{
    if (part != NSScrollerDecrementLine && part != NSScrollerIncrementLine && part != 7 && part != 8)
        return SLDrawingRect(st, part);

    NSUsableScrollerParts usable = SLUsableParts(st);
    if (usable == NSNoScrollerParts || st->fullLengthSlot || st->config == 0) return NSZeroRect;
    if (usable == NSOnlyScrollerArrows && (part == 7 || part == 8)) return NSZeroRect;

    CGFloat outer = st->small ? 12 : 16;       // the arrow at the very end
    CGFloat inner = st->small ? 11 : 14;       // the arrow next to it
    CGFloat max = SLMaxAlong(st);

    switch ((int)part) {
        case NSScrollerDecrementLine:
            if (st->config == kSLArrowsDoubleMax) return SLAlongRect(st, max - (inner + outer), inner);
            return SLAlongRect(st, 0, outer);
        case NSScrollerIncrementLine:
            if (st->config == kSLArrowsDoubleMin) return SLAlongRect(st, outer, inner);
            return SLAlongRect(st, max - outer, outer);
        case 7:
            if (st->config != kSLArrowsDoubleBoth) return NSZeroRect;
            return SLAlongRect(st, max - (inner + outer), inner);
        default:    // 8
            if (st->config != kSLArrowsDoubleBoth) return NSZeroRect;
            return SLAlongRect(st, outer, inner);
    }
}

// _PointInArrow: the arrow art has the rounded end of the track bulging into
// it; clicks on that bulge belong to the track.
static BOOL SLPointInArrow(NSPoint point, NSRect rect, NSRectEdge edge, BOOL small)
{
    NSRect slice;
    NSDivideRect(rect, &slice, &rect, small ? 2 : 3, edge);
    if (!NSPointInRect(point, rect)) return NO;

    CGFloat radius, cx, cy;
    if (edge == NSMinXEdge || edge == NSMaxXEdge) {
        radius = 0.5 * rect.size.height;
        cx = (edge == NSMinXEdge) ? NSMinX(rect) : NSMaxX(rect);
        cy = NSMinY(rect) + radius;
    } else {
        radius = 0.5 * rect.size.width;
        cx = NSMinX(rect) + radius;
        cy = (edge == NSMinYEdge) ? NSMinY(rect) : NSMaxY(rect);
    }
    CGFloat dx = point.x - cx, dy = point.y - cy;
    return dx * dx + dy * dy > radius * radius;
}

// -[NSScroller testPart:], for a point already in the scroller's coordinates.
NSScrollerPart SLHitTest(const SLState *st, NSPoint p)
{
    if (!st->enabled || SLUsableParts(st) == NSNoScrollerParts) return NSScrollerNoPart;
    if (!NSMouseInRect(p, st->bounds, st->flipped)) return NSScrollerNoPart;

    if (NSPointInRect(p, SLDrawingRect(st, NSScrollerKnob))) return NSScrollerKnob;

    CGFloat outer = st->small ? 12 : 16;
    CGFloat w = st->bounds.size.width, h = st->bounds.size.height, t = st->thickness;

    if (st->config != 0 && !st->fullLengthSlot) {
        if (st->config != kSLArrowsDoubleMax) {
            NSRect r = SLDrawingRect(st, NSScrollerDecrementLine);
            if (SLPointInArrow(p, r, st->horizontal ? NSMaxXEdge : NSMaxYEdge, st->small)) {
                if (st->config <= kSLArrowsSingle) return NSScrollerDecrementLine;
                NSRect first = st->horizontal ? NSMakeRect(0, h - t, outer, t) : NSMakeRect(w - t, 0, t, outer);
                return NSPointInRect(p, first) ? NSScrollerDecrementLine : NSScrollerIncrementLine;
            }
        }
        if (st->config != kSLArrowsDoubleMin) {
            NSRect r = SLDrawingRect(st, NSScrollerIncrementLine);
            if (SLPointInArrow(p, r, st->horizontal ? NSMinXEdge : NSMinYEdge, st->small)) {
                if (st->config <= kSLArrowsSingle) return NSScrollerIncrementLine;
                NSRect last = st->horizontal ? NSMakeRect(w - outer, h - t, outer, t) : NSMakeRect(w - t, h - outer, t, outer);
                return NSPointInRect(p, last) ? NSScrollerIncrementLine : NSScrollerDecrementLine;
            }
        }
    }

    if (NSPointInRect(p, SLDrawingRect(st, NSScrollerDecrementPage))) {
        if (st->fullLengthSlot || (st->config != 0 && st->config != kSLArrowsDoubleMax)) return NSScrollerDecrementPage;
        // The near end is a bare rounded cap: its corners are dead.
        CGFloat radius = st->small ? 5.5 : 7.5;
        CGFloat edge = 2 + kArrowsInset[st->small ? 1 : 0][0] + radius;
        CGFloat along = (st->horizontal ? p.x : p.y) - edge;
        if (!(along < 0)) return NSScrollerDecrementPage;
        CGFloat across = (st->horizontal ? p.y : p.x) - radius;
        return (along * along + across * across > radius * radius) ? NSScrollerNoPart : NSScrollerDecrementPage;
    }
    if (NSPointInRect(p, SLDrawingRect(st, NSScrollerIncrementPage))) return NSScrollerIncrementPage;
    return NSScrollerNoPart;
}

// ---- painting ----------------------------------------------------------------

static inline int SLKind(int regularKind, BOOL small) { return small ? regularKind + 200 : regularKind; }

// -[NSScroller _old_drawKnobSlotInRect:highlight:]
void SLPaintSlot(const SLState *st, NSRect rect)
{
    int dir = st->horizontal ? 0 : 0x100;
    int kind = SLKind(kSLKindTrack, st->small);

    if (SLUsableParts(st) == NSNoScrollerParts) {
        // Nothing to scroll: a flat, lighter track from end to end.
        SLTileImage(SLThemeImage(kind, 3, dir, 0, 0, YES), rect, NSZeroPoint, st->flipped);
    } else {
        SLDrawThreePart(SLThemeImage(kind, 0, dir, 0, 0, NO), SLThemeImage(kind, 0, dir, 0, 0, YES), rect, !st->horizontal, st->flipped);
    }
}

// -[NSScroller _old_drawKnob]
//
// This is where the stripes come from. The thumb's middle is a 16 pixel
// (12 for small scrollers) wave pattern anchored to the scroll bar, not to
// the thumb, so the thumb slides over it like a window; and the two rounded
// caps exist in 16 (12) pre-rendered variants, one per pattern phase, picked
// by the thumb's position so the caps always continue the pattern.
void SLPaintKnob(const SLState *st)
{
    NSRect rect = SLDrawingRect(st, NSScrollerKnob);
    if (NSIsEmptyRect(rect)) return;

    BOOL flipped = st->flipped;
    BOOL vertical = !st->horizontal;
    int state = st->active ? 0 : 3;
    int dir = vertical ? 0x100 : 0;
    int kind = SLKind(kSLKindThumb, st->small);
    int tint = (int)st->tint;
    long period = st->small ? 12 : 16;
    CGFloat thickness = st->thickness;

    CGImageRef fill = SLThemeImage(kind, state, dir, tint, 0, YES);

    if (!st->active) {
        SLDrawThreePart(SLThemeImage(kind, state, dir, tint, 0, NO), fill, rect, vertical, flipped);
        return;
    }

    if (vertical) {
        long phase = (long)rect.origin.y % period;
        CGImageRef caps = SLThemeImage(kind, state, dir, tint, (int)phase, NO);
        CGFloat capLength = floor(SLSnap(0.5 * SLImageSize(caps).height));

        rect = NSInsetRect(rect, (rect.size.width - thickness) * 0.5, 0);
        rect.origin.x = floor(SLSnap(rect.origin.x));

        SLDrawImagePart(caps, NSMakeRect(0, capLength, thickness, capLength),
                        NSMakeRect(rect.origin.x, rect.origin.y, thickness, capLength), flipped);
        SLDrawImagePart(caps, NSMakeRect(0, 0, thickness, capLength),
                        NSMakeRect(rect.origin.x, NSMaxY(rect) - capLength, thickness, capLength), flipped);

        rect = NSInsetRect(rect, 0, capLength);
        if (rect.size.height > 0)
            SLTileImage(fill, rect, NSMakePoint(0, (phase + period - 3) % period), flipped);
    } else {
        long phase = (long)rect.origin.x % period;
        CGImageRef caps = SLThemeImage(kind, state, dir, tint, (int)phase, NO);
        CGFloat capLength = floor(SLSnap(0.5 * SLImageSize(caps).width));

        rect = NSInsetRect(rect, 0, (rect.size.height - thickness) * 0.5);
        rect.origin.y = floor(SLSnap(rect.origin.y));

        SLDrawImagePart(caps, NSMakeRect(0, 0, capLength, thickness),
                        NSMakeRect(rect.origin.x, rect.origin.y, capLength, thickness), flipped);
        SLDrawImagePart(caps, NSMakeRect(capLength, 0, capLength, thickness),
                        NSMakeRect(NSMaxX(rect) - capLength, rect.origin.y, capLength, thickness), flipped);

        rect = NSInsetRect(rect, capLength, 0);
        if (rect.size.width > 0)
            SLTileImage(fill, rect, NSMakePoint((phase + period - 3) % period, 0), flipped);
    }
}

// -[NSScroller _old_drawArrow:highlightPart:]
//
// `arrow` selects which end is being drawn (NSScrollerDecrementArrow = near
// end); `highlightPart` is the arrow that is pressed, or -1.
void SLPaintArrow(const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart)
{
    NSRect rect = SLDrawingRect(st, (arrow == NSScrollerDecrementArrow) ? NSScrollerDecrementLine : NSScrollerIncrementLine);
    if (NSIsEmptyRect(rect)) return;

    BOOL increment = (arrow == NSScrollerIncrementArrow);
    BOOL pressed = (highlightPart != -1);

    // 0x200 up, 0x300 down, 0x400 left, 0x500 right.
    int dir = st->horizontal ? (increment ? 0x500 : 0x400) : (increment ? 0x300 : 0x200);
    int kind, state = 0, tint = NSClearControlTint;

    BOOL capOnly = (st->config == 0)
                || (st->config == kSLArrowsDoubleMin && increment)
                || (st->config == kSLArrowsDoubleMax && !increment);

    if (capOnly) {
        kind = kSLKindEndCap;
    } else if (st->config == kSLArrowsSingle) {
        kind = kSLKindArrowSingle;
        if (!st->arrowsActive) {
            state = 4;
        } else if (pressed && highlightPart == (NSInteger)arrow) {
            state = 2;
            tint = (int)st->tint;
        }
    } else {
        // A pair of arrows: state 2 lights the outer one, 7 the inner one.
        kind = kSLKindArrowDouble;
        if (!st->arrowsActive) {
            state = 4;
        } else if (pressed) {
            tint = (int)st->tint;
            if (st->config == kSLArrowsDoubleMax) state = (highlightPart == NSScrollerIncrementArrow) ? 2 : 7;
            else state = (highlightPart == (NSInteger)arrow) ? 2 : 7;
        }
    }

    CGImageRef image = SLThemeImage(SLKind(kind, st->small), state, dir, tint, 0, NO);
    SLDrawImageAtPoint(image, NSMakePoint(rect.origin.x, st->flipped ? NSMaxY(rect) : rect.origin.y), st->flipped);
}

// The highlightPart -drawRect: passes for each end, from the pressed arrow.
NSInteger SLHighlightPartForEnd(const SLState *st, BOOL nearEnd)
{
    NSInteger pressedArrow = st->pressedArrow;
    int config = st->config;
    if (pressedArrow == -1 || config == 0) return -1;

    if (nearEnd) {
        if (config == kSLArrowsSingle) return (pressedArrow == NSScrollerDecrementArrow) ? pressedArrow : -1;
        if (config == kSLArrowsDoubleMin) return pressedArrow;
        if (config == kSLArrowsDoubleBoth) return st->pressedInMaxEnd ? -1 : pressedArrow;
        return -1;
    }
    if (config == kSLArrowsSingle) return (pressedArrow == NSScrollerIncrementArrow) ? pressedArrow : -1;
    if (config == kSLArrowsDoubleMax) return pressedArrow;
    if (config == kSLArrowsDoubleBoth) return st->pressedInMaxEnd ? pressedArrow : -1;
    return -1;
}

// The whole scroll bar, in -[NSScroller drawRect:]'s order.
void SLPaintAll(const SLState *st)
{
    SLPaintSlot(st, SLDrawingRect(st, NSScrollerKnobSlot));
    if (!st->enabled) return;
    SLPaintArrow(st, NSScrollerDecrementArrow, SLHighlightPartForEnd(st, YES));
    SLPaintArrow(st, NSScrollerIncrementArrow, SLHighlightPartForEnd(st, NO));
    SLPaintKnob(st);
}
