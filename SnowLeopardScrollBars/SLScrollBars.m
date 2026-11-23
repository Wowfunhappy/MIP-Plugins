//
//  SLScrollBars.m
//  Snow Leopard scroll bars for Mavericks (SIMBL plugin).
//
//  Mavericks' NSScroller is still, structurally, Snow Leopard's: -drawRect:
//  walks the same part list, -mouseDown: still dispatches to
//  -trackScrollButtons:, the arrow configuration global is still there. What
//  Lion removed is the geometry (arrows have no rectangles any more) and the
//  drawing (-_old_drawArrow:highlightPart: is an empty stub, the knob and
//  track are delegated to NSScrollerImp).
//
//  This plugin puts those two things back. Everything here is a port of the
//  corresponding routines in AppKit 1038.29 (Mac OS X 10.6.3):
//
//      -[NSScroller rectForPart:]                  hit rectangles
//      -[NSScroller _drawingRectForPart:]          drawing rectangles
//      -[NSScroller checkSpaceForParts]            usable parts
//      -[NSScroller testPart:] / _PointInArrow     hit testing
//      -[NSScroller drawRect:]                     part order + highlight
//      -[NSScroller _old_drawKnob]                 thumb, with moving stripes
//      -[NSScroller _old_drawKnobSlotInRect:highlight:]
//      -[NSScroller _old_drawArrow:highlightPart:]
//      -[NSScroller highlight:]
//
//  Mouse tracking (-mouseDown:, -trackKnob:, -trackScrollButtons:,
//  -trackPagingArea:) is left to Mavericks' own code, which is driven
//  entirely by the methods above.
//

#import "SLScrollBars.h"
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// ---- private AppKit API we rely on ---------------------------------------

@interface NSWindow (SLPrivate)
- (BOOL)_hasActiveControls;
@end

@interface NSScroller (SLPrivate)
+ (int)_arrowsConfig;
+ (void)_setArrowsConfig:(int)config;
- (NSRect)_drawingRectForPart:(NSScrollerPart)part;
- (NSControlTint)_realControlTint;
- (void)drawArrow:(NSScrollerArrow)arrow highlightPart:(NSInteger)part;
- (id)scrollerImp;
@end

@interface NSObject (SLScrollerImpPrivate)
- (CALayer *)trackLayer;
- (void)setTrackLayer:(CALayer *)layer;
- (CALayer *)knobLayer;
- (void)setKnobLayer:(CALayer *)layer;
@end

@interface NSView (SLPrivate)
- (void)_resetSupportsDirectLayerContentsCache;
@end

// ---- scroller configuration ----------------------------------------------

static int gArrowConfig = kSLArrowsDoubleMax;
static BOOL gEnabled = NO;

static ptrdiff_t gSFlagsOffset = 0;      // NSScroller.sFlags
static ptrdiff_t gSFlags2Offset = 0;     // NSScroller._sFlags2

// Bits in NSScroller.sFlags / _sFlags2 (unchanged between 10.6 and 10.9).
#define SL_SFLAGS(s)        (*(unsigned int *)((char *)(s) + gSFlagsOffset))
#define SL_SFLAGS2(s)       (*(unsigned int *)((char *)(s) + gSFlags2Offset))
#define kSFlagHorizontal    0x0001
#define kSFlagPartHit       0x0400      // set by -highlight:
#define kSFlags2HitPartMask 0x000f
#define kSFlags2MaxEndHit   0x0040      // DoubleBoth: the pressed arrow is in the max-end pair

static inline BOOL SLIsLegacy(NSScroller *scroller)
{
    return gEnabled && [scroller scrollerStyle] == NSScrollerStyleLegacy;
}

int SLArrowConfig(void) { return gArrowConfig; }
BOOL SLIsEnabled(void) { return gEnabled; }

static BOOL SLHasActiveControls(NSScroller *scroller)
{
    NSWindow *window = [scroller window];
    return [window respondsToSelector:@selector(_hasActiveControls)] ? [window _hasActiveControls] : [window isKeyWindow];
}

static NSControlTint SLRealControlTint(NSScroller *scroller)
{
    if ([scroller respondsToSelector:@selector(_realControlTint)]) return [scroller _realControlTint];
    return SLHasActiveControls(scroller) ? [NSColor currentControlTint] : NSClearControlTint;
}

static SLState SLStateForScroller(NSScroller *scroller)
{
    SLState st;
    memset(&st, 0, sizeof(st));
    st.bounds = [scroller bounds];
    st.horizontal = (SL_SFLAGS(scroller) & kSFlagHorizontal) != 0;
    st.small = ([scroller controlSize] == NSSmallControlSize);
    st.enabled = [scroller isEnabled];
    st.flipped = [scroller isFlipped];
    st.config = ([scroller arrowsPosition] == NSScrollerArrowsNone) ? 0 : gArrowConfig;
    st.thickness = st.small ? 11 : 15;
    st.value = [scroller doubleValue];
    st.proportion = [scroller knobProportion];
    st.active = SLHasActiveControls(scroller);
    st.arrowsActive = st.active || [[scroller window] isMainWindow];
    st.tint = SLRealControlTint(scroller);

    unsigned hit = SL_SFLAGS2(scroller) & kSFlags2HitPartMask;
    st.pressedArrow = -1;
    if (SL_SFLAGS(scroller) & kSFlagPartHit) {
        if (hit == NSScrollerDecrementLine) st.pressedArrow = NSScrollerDecrementArrow;
        else if (hit == NSScrollerIncrementLine) st.pressedArrow = NSScrollerIncrementArrow;
    }
    st.pressedInMaxEnd = (SL_SFLAGS2(scroller) & kSFlags2MaxEndHit) != 0;
    return st;
}

// ---- NSScroller overrides ---------------------------------------------------

#define SL_ORIG(name) orig_##name

static NSRect (*SL_ORIG(rectForPart))(id, SEL, NSScrollerPart);
static NSRect (*SL_ORIG(drawingRectForPart))(id, SEL, NSScrollerPart);
static NSUsableScrollerParts (*SL_ORIG(usableParts))(id, SEL);
static NSScrollerPart (*SL_ORIG(testPart))(id, SEL, NSPoint);
static void (*SL_ORIG(drawRect))(id, SEL, NSRect);
static void (*SL_ORIG(drawKnob))(id, SEL);
static void (*SL_ORIG(drawKnobSlot))(id, SEL, NSRect, BOOL);
static void (*SL_ORIG(oldDrawArrow))(id, SEL, NSScrollerArrow, NSInteger);
static void (*SL_ORIG(drawArrowHighlight))(id, SEL, NSScrollerArrow, BOOL);
static void (*SL_ORIG(highlight))(id, SEL, BOOL);
static void (*SL_ORIG(windowChangedKeyState))(id, SEL);
static BOOL (*SL_ORIG(wantsUpdateLayer))(id, SEL);
static BOOL (*SL_ORIG(isOpaque))(id, SEL);
static void (*SL_ORIG(mouseDown))(id, SEL, NSEvent *);
static NSInteger (*SL_ORIG(hysteresisCheck))(id, SEL, NSEvent *, NSDate *, NSSize, NSPoint *);
static void (*SL_ORIG(startPeriodicEvents))(id, SEL, NSTimeInterval, NSTimeInterval);
static BOOL (*SL_ORIG(edgeResizingCursorUpdate))(id, SEL, NSEvent *, NSPoint);
static CGFloat (*SL_ORIG(impKnobLength))(id, SEL);
static CGFloat (*SL_ORIG(impKnobEndInset))(id, SEL);
static void (*SL_ORIG(impSetLayer))(id, SEL, CALayer *);
static void (*SL_ORIG(setNeedsDisplay))(id, SEL, BOOL);
static void (*SL_ORIG(setNeedsDisplayInRect))(id, SEL, NSRect);
static void (*SL_ORIG(setNeedsDisplayIfNotLB))(id, SEL);
static void (*SL_ORIG(setNeedsDisplayIfNotLBInRect))(id, SEL, NSRect);
static BOOL (*SL_ORIG(isCompatibleWithOverlay))(id, SEL);
static void (*SL_ORIG(reallySetStyle))(id, SEL, NSScrollerStyle);
static NSInteger (*SL_ORIG(recommendedStyle))(id, SEL);
static void (*SL_ORIG(setRecommendedStyle))(id, SEL, NSInteger);

static NSRect sl_rectForPart(NSScroller *self, SEL _cmd, NSScrollerPart part)
{
    if (!SLIsLegacy(self)) return SL_ORIG(rectForPart)(self, _cmd, part);
    SLState st = SLStateForScroller(self);
    return SLHitRect(&st, part);
}

static NSRect sl_drawingRectForPart(NSScroller *self, SEL _cmd, NSScrollerPart part)
{
    if (!SLIsLegacy(self)) return SL_ORIG(drawingRectForPart)(self, _cmd, part);
    SLState st = SLStateForScroller(self);
    return SLDrawingRect(&st, part);
}

static NSUsableScrollerParts sl_usableParts(NSScroller *self, SEL _cmd)
{
    if (!SLIsLegacy(self)) return SL_ORIG(usableParts)(self, _cmd);
    SLState st = SLStateForScroller(self);
    return SLUsableParts(&st);
}

static NSScrollerPart sl_testPart(NSScroller *self, SEL _cmd, NSPoint point)
{
    if (!SLIsLegacy(self)) return SL_ORIG(testPart)(self, _cmd, point);
    SLState st = SLStateForScroller(self);
    return SLHitTest(&st, [self convertPoint:point fromView:nil]);
}

static void sl_drawRect(NSScroller *self, SEL _cmd, NSRect dirty)
{
    if (!SLIsLegacy(self)) { SL_ORIG(drawRect)(self, _cmd, dirty); return; }

    if (![self isEnabled]) {
        [self drawKnobSlotInRect:[self _drawingRectForPart:NSScrollerKnobSlot] highlight:NO];
        return;
    }

    static const NSScrollerPart order[4] = { NSScrollerKnobSlot, NSScrollerDecrementLine, NSScrollerIncrementLine, NSScrollerKnob };
    SLState st = SLStateForScroller(self);

    for (int i = 0; i < 4; i++) {
        NSRect rect = [self _drawingRectForPart:order[i]];
        if (NSIsEmptyRect(rect) || NSIsEmptyRect(NSIntersectionRect(rect, dirty))) continue;
        switch (order[i]) {
            case NSScrollerKnobSlot:
                [self drawKnobSlotInRect:rect highlight:NO];
                break;
            case NSScrollerDecrementLine:
                [self drawArrow:NSScrollerDecrementArrow highlightPart:SLHighlightPartForEnd(&st, YES)];
                break;
            case NSScrollerIncrementLine:
                [self drawArrow:NSScrollerIncrementArrow highlightPart:SLHighlightPartForEnd(&st, NO)];
                break;
            default:
                [self drawKnob];
                break;
        }
    }
}

static void sl_drawKnob(NSScroller *self, SEL _cmd)
{
    if (!SLIsLegacy(self)) { SL_ORIG(drawKnob)(self, _cmd); return; }
    SLState st = SLStateForScroller(self);
    SLPaintKnob(&st);
}

static void sl_drawKnobSlot(NSScroller *self, SEL _cmd, NSRect rect, BOOL highlight)
{
    if (!SLIsLegacy(self)) { SL_ORIG(drawKnobSlot)(self, _cmd, rect, highlight); return; }
    SLState st = SLStateForScroller(self);
    SLPaintSlot(&st, rect);
}

static void sl_oldDrawArrow(NSScroller *self, SEL _cmd, NSScrollerArrow arrow, NSInteger highlightPart)
{
    if (!SLIsLegacy(self)) { SL_ORIG(oldDrawArrow)(self, _cmd, arrow, highlightPart); return; }
    SLState st = SLStateForScroller(self);
    SLPaintArrow(&st, arrow, highlightPart);
}

static void sl_drawArrowHighlight(NSScroller *self, SEL _cmd, NSScrollerArrow arrow, BOOL highlight)
{
    if (!SLIsLegacy(self)) { SL_ORIG(drawArrowHighlight)(self, _cmd, arrow, highlight); return; }
    NSScrollerPart part = (arrow == NSScrollerDecrementArrow) ? NSScrollerDecrementLine : NSScrollerIncrementLine;
    if (NSIsEmptyRect([self _drawingRectForPart:part])) return;
    [self drawArrow:arrow highlightPart:highlight ? (NSInteger)arrow : -1];
}

static void sl_highlight(NSScroller *self, SEL _cmd, BOOL flag)
{
    if (!SLIsLegacy(self)) { SL_ORIG(highlight)(self, _cmd, flag); return; }

    if (flag) SL_SFLAGS(self) |= kSFlagPartHit; else SL_SFLAGS(self) &= ~kSFlagPartHit;

    unsigned flags2 = SL_SFLAGS2(self);
    unsigned hit = flags2 & kSFlags2HitPartMask;
    int config = ([self arrowsPosition] == NSScrollerArrowsNone) ? 0 : gArrowConfig;
    NSScrollerPart part;

    if (hit == NSScrollerDecrementLine || hit == NSScrollerIncrementLine) {
        if (config == kSLArrowsDoubleBoth) part = (flags2 & kSFlags2MaxEndHit) ? NSScrollerIncrementLine : NSScrollerDecrementLine;
        else if (config == kSLArrowsDoubleMin) part = NSScrollerDecrementLine;
        else if (config == kSLArrowsDoubleMax) part = NSScrollerIncrementLine;
        else part = (NSScrollerPart)hit;
    } else if (hit == NSScrollerDecrementPage || hit == NSScrollerIncrementPage) {
        part = (NSScrollerPart)hit;
    } else {
        return;
    }
    [self setNeedsDisplayInRect:[self _drawingRectForPart:part]];
}

static void sl_windowChangedKeyState(NSScroller *self, SEL _cmd)
{
    SL_ORIG(windowChangedKeyState)(self, _cmd);
    // Arrows, caps and thumb all change between active and inactive windows.
    if (SLIsLegacy(self)) [self setNeedsDisplay:YES];
}

// AppKit asks this of a scroller's class to decide whether it may (a) use the
// overlay style and (b) when layer-backed, be composed from NSScrollerImp's
// private track/knob layers instead of calling -drawRect:. While the user's
// setting gives legacy scrollers, saying no - which is what any pre-Lion
// NSScroller subclass effectively says - puts all drawing back in -drawRect:.
// With overlay scrollers ("show scroll bars when scrolling") AppKit is left to
// do exactly what it would without the plugin.
static BOOL sl_isCompatibleWithOverlay(id self, SEL _cmd)
{
    static BOOL inside = NO;
    if (!gEnabled || inside) return SL_ORIG(isCompatibleWithOverlay)(self, _cmd);
    inside = YES;
    BOOL legacy = ([NSScroller preferredScrollerStyle] == NSScrollerStyleLegacy);
    inside = NO;
    return legacy ? NO : SL_ORIG(isCompatibleWithOverlay)(self, _cmd);
}

static BOOL sl_wantsUpdateLayer(NSScroller *self, SEL _cmd)
{
    if (!SLIsLegacy(self)) return SL_ORIG(wantsUpdateLayer)(self, _cmd);
    return NO;
}

static BOOL sl_isOpaque(NSScroller *self, SEL _cmd)
{
    if (!SLIsLegacy(self)) return SL_ORIG(isOpaque)(self, _cmd);
    return YES;
}

static void sl_mouseDown(NSScroller *self, SEL _cmd, NSEvent *event)
{
    if (SLIsLegacy(self) && gArrowConfig == kSLArrowsDoubleBoth && [self arrowsPosition] != NSScrollerArrowsNone) {
        // Remember which of the two arrow pairs the click landed in, so the
        // right pair lights up.
        SLState st = SLStateForScroller(self);
        NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
        CGFloat along = st.horizontal ? p.x : p.y;
        CGFloat length = st.horizontal ? st.bounds.size.width : st.bounds.size.height;
        if (along > length * 0.5) SL_SFLAGS2(self) |= kSFlags2MaxEndHit; else SL_SFLAGS2(self) &= ~kSFlags2MaxEndHit;
    }
    SL_ORIG(mouseDown)(self, _cmd, event);
}

/* Pressing and holding a scroll arrow in a window's resize corner.

   Mavericks lets any window be resized from its corners, and the bottom-right
   one is where a lone vertical scroller has its down arrow. A mouse-down
   there goes through -[NSWindow _hitTestWithHysteresisCheck:forEvent:
   allowWindowDragging:], which waits in +_mouseHysteresisCheck:withExpiration:
   andDistance:finalMouseLocation: for the mouse to move (a resize) or come up
   (then the click goes to the view under it, on mouse-up). AppKit passes
   [NSDate distantFuture], so holding the button still never reaches the
   scroller and an arrow can't be held down to keep scrolling.

   For a press on a scroll arrow (an NSScroller's, or a WebKit2 page's, which
   Safari draws in another process), the wait gets an expiration: held
   still for kSLArrowHoldDelay, the check returns "expired", which AppKit
   treats like a click, but now with the button still down, so the scroller
   tracks it (-trackScrollButtons:, or WebKit's own tracking) and repeats.
   Moving first still resizes;
   a quick click still works on mouse-up.

   The scroller waits gButtonDelay (0.5 s) before it starts repeating; that
   wait is shortened by the time the press was already held, so repeating
   starts when it would have without the hold.

   The resize cursor goes too: AppKit shows it as an override cursor
   (+[NSCursor _setOverrideCursor:], from -[NSWindow _edgeResizingCursorUpdate:
   atLocation:]), which is cleared at the hand-over and not put back while
   the button is down; when it comes up, the window's edge cursor is brought
   up to date for wherever the mouse is. */
// As long as an arrow's own wait before repeating (gButtonDelay, 0.5 s), so a
// short pause before dragging still resizes, and repeating still starts on time.
static const NSTimeInterval kSLArrowHoldDelay = 0.5;
static NSTimeInterval gHeldPressDuration;      // how long a press handed to a scroller had been held
static NSTimeInterval gHeldPressHandedOver;    // when (system uptime)
static BOOL gHeldPressActive;                  // a handed-over press may still be down
static NSWindow *gHeldPressWindow;             // its window (retained while it is)

// The window's edge cursor for wherever the mouse is now (as on a mouse move).
static void SLRefreshEdgeCursor(NSWindow *window)
{
    NSPoint location = [window mouseLocationOutsideOfEventStream];
    NSEvent *moved = [NSEvent mouseEventWithType:NSMouseMoved location:location modifierFlags:0
                                       timestamp:[[NSProcessInfo processInfo] systemUptime]
                                    windowNumber:[window windowNumber] context:nil eventNumber:0 clickCount:0 pressure:0];
    SL_ORIG(edgeResizingCursorUpdate)(window, NSSelectorFromString(@"_edgeResizingCursorUpdate:atLocation:"), moved, location);
}

@interface SLHeldPressWatcher : NSObject
@end
@implementation SLHeldPressWatcher
// Polls for the end of a handed-over press: scrollers take the mouse-up inside
// their own tracking loop, so it may never pass through the window.
+ (void)watch
{
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(check:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
}
+ (void)check:(NSTimer *)timer
{
    if (gHeldPressActive && ([NSEvent pressedMouseButtons] & 1)) return;
    [timer invalidate];
    NSWindow *window = gHeldPressWindow;
    gHeldPressWindow = nil;
    if (gHeldPressActive) {
        gHeldPressActive = NO;
        if (window && SL_ORIG(edgeResizingCursorUpdate)) SLRefreshEdgeCursor(window);
    }
    [window release];
}
@end

static inline BOOL SLIsArrowPart(NSScrollerPart part)
{
    return part == NSScrollerDecrementLine || part == NSScrollerIncrementLine;
}

// A WebKit2 view (Safari's page): its scroll bars are drawn in the web
// process, but the page proxy here knows whether the page has them, and
// their layout follows from their frame alone (SLStateForWebCoreScrollbar in
// SLWebKit.m): the vertical one runs down the view's right edge, 15 points
// wide, stopping short of the bottom-right corner when there is a horizontal
// one too, with the arrows where the arrow setting puts them.
static BOOL SLPointIsOnWebKitScrollArrow(NSView *view, NSPoint pointInWindow)
{
    static Class wkView;
    static BOOL (*hasVertical)(const void *), (*hasHorizontal)(const void *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wkView = NSClassFromString(@"WKView");
        hasVertical = dlsym(RTLD_DEFAULT, "WKPageHasVerticalScrollbar");
        hasHorizontal = dlsym(RTLD_DEFAULT, "WKPageHasHorizontalScrollbar");
    });
    if (!wkView || !hasVertical || !hasHorizontal) return NO;
    while (view && ![view isKindOfClass:wkView]) view = [view superview];
    if (!view || ![view respondsToSelector:@selector(pageRef)]) return NO;
    const void *page = ((const void *(*)(id, SEL))objc_msgSend)(view, @selector(pageRef));
    if (!page || !hasVertical(page)) return NO;

    const CGFloat width = 15;
    NSRect b = [view bounds];
    NSPoint p = [view convertPoint:pointInWindow fromView:nil];
    CGFloat fromTop = [view isFlipped] ? p.y - NSMinY(b) : NSMaxY(b) - p.y;

    SLState st;
    memset(&st, 0, sizeof(st));
    st.bounds = NSMakeRect(0, 0, width, b.size.height - (hasHorizontal(page) ? width : 0));
    st.thickness = width;
    st.enabled = YES;
    st.flipped = YES;
    st.config = SLArrowConfig();
    st.webKitMetrics = YES;
    st.value = 0.5;             // (the knob is never on an arrow; keep it in the middle)
    st.pressedArrow = -1;
    return SLIsArrowPart(SLHitTest(&st, NSMakePoint(p.x - (NSMaxX(b) - width), fromTop)));
}

// Is the mouse-down on a scroll arrow?
static BOOL SLEventIsOnScrollArrow(NSEvent *event)
{
    NSWindow *window = [event window];
    NSView *frame = [[window contentView] superview];
    if (!frame) return NO;
    NSPoint p = [event locationInWindow];
    NSView *hit = [frame respondsToSelector:@selector(_hitTest:ignoringResizeRegion:)]
                ? ((NSView *(*)(id, SEL, NSPoint, BOOL))objc_msgSend)(frame, @selector(_hitTest:ignoringResizeRegion:), p, YES)
                : [frame hitTest:p];
    if ([hit isKindOfClass:[NSScroller class]])
        return SLIsLegacy((NSScroller *)hit) && SLIsArrowPart([(NSScroller *)hit testPart:p]);
    return SLPointIsOnWebKitScrollArrow(hit, p);
}

static NSInteger sl_hysteresisCheck(id self, SEL _cmd, NSEvent *event, NSDate *expiration, NSSize distance, NSPoint *location)
{
    if ([expiration timeIntervalSinceNow] > 3600 && [event type] == NSLeftMouseDown && SLEventIsOnScrollArrow(event)) {
        NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
        NSTimeInterval wait = MAX(0, kSLArrowHoldDelay - (now - [event timestamp]));
        NSInteger result = SL_ORIG(hysteresisCheck)(self, _cmd, event, [NSDate dateWithTimeIntervalSinceNow:wait], distance, location);
        if (result == 1) {          // expired: held still, so it goes to the scroller as a press
            gHeldPressHandedOver = [[NSProcessInfo processInfo] systemUptime];
            gHeldPressDuration = gHeldPressHandedOver - [event timestamp];
            // No longer a resize: drop the resize cursor.
            gHeldPressActive = YES;
            [gHeldPressWindow release];
            gHeldPressWindow = [[event window] retain];
            [SLHeldPressWatcher watch];
            if ([NSCursor respondsToSelector:@selector(_setOverrideCursor:)])
                ((void (*)(id, SEL, id))objc_msgSend)([NSCursor class], @selector(_setOverrideCursor:), nil);
            [[NSCursor arrowCursor] set];
        }
        return result;
    }
    return SL_ORIG(hysteresisCheck)(self, _cmd, event, expiration, distance, location);
}

static BOOL sl_edgeResizingCursorUpdate(id self, SEL _cmd, NSEvent *event, NSPoint location)
{
    if (gHeldPressActive && ([NSEvent pressedMouseButtons] & 1))
        return NO;          // still pressing the scroll bar: no resize cursor
    return SL_ORIG(edgeResizingCursorUpdate)(self, _cmd, event, location);
}

static void sl_startPeriodicEvents(id self, SEL _cmd, NSTimeInterval delay, NSTimeInterval period)
{
    if (gHeldPressDuration > 0) {
        // The scroller tracking the press handed over above (within the same event).
        if ([[NSProcessInfo processInfo] systemUptime] - gHeldPressHandedOver < 0.1)
            delay = MAX(0, delay - gHeldPressDuration);
        gHeldPressDuration = 0;
    }
    SL_ORIG(startPeriodicEvents)(self, _cmd, delay, period);
}

/* A layer-backed NSScroller leaves redrawing to its NSScrollerImp's track and
   knob layers and ignores requests to redraw itself. Those layers are removed
   for Snow Leopard scrollers (SLRemoveImpPartLayers), so pass the requests on
   to NSView as for any other view; otherwise the scroller's layer keeps (and
   stretches) whatever it first drew. */
static BOOL SLDrawsOwnLayer(NSScroller *scroller)
{
    return SLIsLegacy(scroller) && [scroller layer] != nil;
}

static void sl_setNeedsDisplay(NSScroller *self, SEL _cmd, BOOL flag)
{
    if (!SLDrawsOwnLayer(self)) { SL_ORIG(setNeedsDisplay)(self, _cmd, flag); return; }
    ((void (*)(id, SEL, BOOL))class_getMethodImplementation([NSView class], _cmd))(self, _cmd, flag);
}

static void sl_setNeedsDisplayInRect(NSScroller *self, SEL _cmd, NSRect rect)
{
    if (!SLDrawsOwnLayer(self)) { SL_ORIG(setNeedsDisplayInRect)(self, _cmd, rect); return; }
    ((void (*)(id, SEL, NSRect))class_getMethodImplementation([NSView class], _cmd))(self, _cmd, rect);
}

static void sl_setNeedsDisplayIfNotLB(NSScroller *self, SEL _cmd)
{
    if (!SLDrawsOwnLayer(self)) { SL_ORIG(setNeedsDisplayIfNotLB)(self, _cmd); return; }
    ((void (*)(id, SEL, BOOL))class_getMethodImplementation([NSView class], @selector(setNeedsDisplay:)))(self, @selector(setNeedsDisplay:), YES);
}

static void sl_setNeedsDisplayIfNotLBInRect(NSScroller *self, SEL _cmd, NSRect rect)
{
    if (!SLDrawsOwnLayer(self)) { SL_ORIG(setNeedsDisplayIfNotLBInRect)(self, _cmd, rect); return; }
    ((void (*)(id, SEL, NSRect))class_getMethodImplementation([NSView class], @selector(setNeedsDisplayInRect:)))(self, @selector(setNeedsDisplayInRect:), rect);
}

// Every change of a scroller's style ("Show scroll bars" switched, a mouse
// plugged in, an app setting it) ends up here; AppKit swaps the scroller's
// NSScrollerImp before returning. Tidy up that scroller right after.
@interface SLScrollBars : NSObject
+ (void)refreshScroller:(NSScroller *)scroller;
@end

static void sl_reallySetStyle(NSScroller *self, SEL _cmd, NSScrollerStyle style)
{
    NSScrollerStyle before = [self scrollerStyle];
    SL_ORIG(reallySetStyle)(self, _cmd, style);
    if (gEnabled && [self scrollerStyle] != before) [SLScrollBars refreshScroller:self];
}

// ---- NSScrollerImp overrides -----------------------------------------------
//
// Mavericks' -trackKnob: and jump-to-click code ask the scroller's
// NSScrollerImp how long the knob is and how far it is inset from the slot's
// ends. Answer with the 10.6 values so dragging maps the same way.

static NSScroller *SLScrollerForImp(id imp)
{
    if (!gEnabled || ![imp respondsToSelector:@selector(scroller)]) return nil;
    NSScroller *scroller = [imp performSelector:@selector(scroller)];
    if (![scroller isKindOfClass:[NSScroller class]] || !SLIsLegacy(scroller)) return nil;
    return scroller;
}

/* A layer-backed scroller's NSScrollerImp puts track and knob layers of its
   own on top of the scroller's layer, laid out with Mavericks' geometry. The
   scroller's own layer gets the Snow Leopard drawing; remove those. AppKit
   adds them whenever the imp is given a layer, which can happen at any time
   (a view tree becoming layer-backed, e.g. Finder's Cover Flow). */
static void SLRemoveImpPartLayers(id imp, NSScroller *scroller)
{
    if (![scroller layer] || ![imp respondsToSelector:@selector(trackLayer)] || ![imp respondsToSelector:@selector(setTrackLayer:)] ||
        ![imp respondsToSelector:@selector(knobLayer)] || ![imp respondsToSelector:@selector(setKnobLayer:)]) return;
    if ([imp trackLayer] || [imp knobLayer]) {
        [[imp trackLayer] removeFromSuperlayer];
        [imp setTrackLayer:nil];
        [[imp knobLayer] removeFromSuperlayer];
        [imp setKnobLayer:nil];
    }
    // With those gone the scroller's own layer is all there is, so it must be
    // redrawn when the scroller is resized, rather than stretched (AppKit's
    // default policy for a layer-backed scroller is never to redraw).
    [scroller setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawDuringViewResize];
    [scroller setNeedsDisplay:YES];
}

static void sl_impSetLayer(id self, SEL _cmd, CALayer *layer)
{
    SL_ORIG(impSetLayer)(self, _cmd, layer);
    NSScroller *scroller = SLScrollerForImp(self);
    if (scroller) SLRemoveImpPartLayers(self, scroller);
}

static CGFloat sl_impKnobLength(id self, SEL _cmd)
{
    NSScroller *scroller = SLScrollerForImp(self);
    if (!scroller) return SL_ORIG(impKnobLength)(self, _cmd);

    SLState st = SLStateForScroller(scroller);
    if (SLUsableParts(&st) != NSAllScrollerParts) return SL_ORIG(impKnobLength)(self, _cmd);
    NSRect knob = SLDrawingRect(&st, NSScrollerKnob);
    return st.horizontal ? knob.size.width : knob.size.height;
}

static CGFloat sl_impKnobEndInset(id self, SEL _cmd)
{
    if (!SLScrollerForImp(self)) return SL_ORIG(impKnobEndInset)(self, _cmd);
    return 0;
}

// ---- scroller style ------------------------------------------------------------
//
// Snow Leopard had no overlay scrollers, so the plugin turns AppKit's
// recommendation into the legacy style - except when System Preferences >
// General > Show scroll bars is "When scrolling", where it changes nothing at
// all and the plugin stays out of the way.
//
// AppKit's private _NSScrollerStyleRecommender stores its recommendation in
// -setRecommendedScrollerStyleAndNotify:, which posts
// NSPreferredScrollerStyleDidChangeNotification when the stored value changes;
// scroll views (and WebKit) follow that notification. Adjusting the value
// there keeps that machinery working when the setting is switched.

static BOOL SLScrollBarsOnlyWhenScrolling(void)
{
    NSString *setting = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleShowScrollBars"];
    return [setting isEqualToString:@"WhenScrolling"];
}

static NSInteger SLEffectiveStyle(NSInteger recommended)
{
    if (!gEnabled || SLScrollBarsOnlyWhenScrolling()) return recommended;
    return NSScrollerStyleLegacy;
}

static void sl_setRecommendedStyle(id self, SEL _cmd, NSInteger style)
{
    SL_ORIG(setRecommendedStyle)(self, _cmd, SLEffectiveStyle(style));
}

static NSInteger sl_recommendedStyle(id self, SEL _cmd)
{
    return SLEffectiveStyle(SL_ORIG(recommendedStyle)(self, _cmd));
}

// ---- setup -----------------------------------------------------------------

BOOL SLHook(Class cls, SEL sel, IMP replacement, IMP *original)
{
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    // If the method is only inherited, give this class its own copy first so
    // the superclass is left alone.
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        *original = method_getImplementation(method);
    } else {
        *original = method_setImplementation(method, replacement);
    }
    return YES;
}

@implementation SLScrollBars

// ___NSSetScrollerVariant
+ (void)readArrowVariant
{
    [[NSUserDefaults standardUserDefaults] synchronize];
    id variant = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleScrollBarVariant"];
    int config = kSLArrowsDoubleMax;
    if ([variant isKindOfClass:[NSString class]]) {
        if ([variant isEqualToString:@"Single"]) config = kSLArrowsSingle;
        else if ([variant isEqualToString:@"DoubleMin"]) config = kSLArrowsDoubleMin;
        else if ([variant isEqualToString:@"DoubleBoth"]) config = kSLArrowsDoubleBoth;
    }
    gArrowConfig = config;
    if ([NSScroller respondsToSelector:@selector(_setArrowsConfig:)]) [NSScroller _setArrowsConfig:config];
}

// Brings one scroller in line with its current style: called when the plugin
// arrives in an already-running process, and whenever AppKit switches a
// scroller's style (sl_reallySetStyle).
+ (void)refreshScroller:(NSScroller *)scroller
{
    if (!SLIsLegacy(scroller)) {
        // Overlay ("show scroll bars when scrolling"). Overlay scrollers draw
        // in the scroller imp's own sublayers and never redraw their backing
        // layer, which would otherwise keep the last Snow Leopard frame. Leave
        // it empty, as it is without the plugin.
        if ([scroller layer]) [[scroller layer] setContents:nil];
        if ([scroller respondsToSelector:@selector(_resetSupportsDirectLayerContentsCache)])
            [scroller _resetSupportsDirectLayerContentsCache];
        [scroller setNeedsDisplay:YES];
        return;
    }
    id imp = [scroller respondsToSelector:@selector(scrollerImp)] ? [scroller scrollerImp] : nil;
    SLRemoveImpPartLayers(imp, scroller);
    // AppKit caches, per view, whether the view fills its layer through
    // -updateLayer (which overlay scrollers do) or -drawRect:.
    if ([scroller respondsToSelector:@selector(_resetSupportsDirectLayerContentsCache)])
        [scroller _resetSupportsDirectLayerContentsCache];
    [scroller setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawDuringViewResize];
    [scroller checkSpaceForParts];
    [scroller setNeedsDisplay:YES];
}

+ (void)refreshView:(NSView *)view
{
    if ([view isKindOfClass:[NSScrollView class]]) [(NSScrollView *)view tile];
    if ([view isKindOfClass:[NSScroller class]]) [self refreshScroller:(NSScroller *)view];
    for (NSView *subview in [view subviews]) [self refreshView:subview];
}

+ (void)refreshAllScrollers
{
    for (NSWindow *window in [NSApp windows]) {
        NSView *root = [[window contentView] superview] ?: [window contentView];
        if (root) [self refreshView:root];
    }
}

+ (void)arrowVariantChanged:(NSNotification *)note
{
    [self readArrowVariant];
    [self refreshAllScrollers];
}

// Not called +install: SIMBL sends +install (as well as +load) to a plugin's
// principal class, and hooking everything twice would point each "original"
// implementation back at its own replacement.
+ (void)setUpScrollBars
{
    static BOOL done = NO;
    if (done) return;
    done = YES;

    // This is a port of one specific AppKit onto another specific AppKit.
    if (floor(NSAppKitVersionNumber) != 1265) return;

    Class scroller = [NSScroller class];
    Ivar sFlags = class_getInstanceVariable(scroller, "sFlags");
    Ivar sFlags2 = class_getInstanceVariable(scroller, "_sFlags2");
    if (!sFlags || !sFlags2) return;
    gSFlagsOffset = ivar_getOffset(sFlags);
    gSFlags2Offset = ivar_getOffset(sFlags2);

    if (![scroller instancesRespondToSelector:@selector(_drawingRectForPart:)] ||
        ![scroller instancesRespondToSelector:@selector(drawArrow:highlightPart:)] ||
        ![scroller instancesRespondToSelector:@selector(_old_drawArrow:highlightPart:)]) return;

    if (!SLArtLoad()) {
        NSLog(@"SnowLeopardScrollBars: could not load scroll bar art from HIToolbox's Extras2.rsrc; leaving scroll bars alone.");
        return;
    }

    [self readArrowVariant];

    BOOL ok = YES;
    ok &= SLHook(scroller, @selector(rectForPart:), (IMP)sl_rectForPart, (IMP *)&SL_ORIG(rectForPart));
    ok &= SLHook(scroller, @selector(_drawingRectForPart:), (IMP)sl_drawingRectForPart, (IMP *)&SL_ORIG(drawingRectForPart));
    ok &= SLHook(scroller, @selector(usableParts), (IMP)sl_usableParts, (IMP *)&SL_ORIG(usableParts));
    ok &= SLHook(scroller, @selector(testPart:), (IMP)sl_testPart, (IMP *)&SL_ORIG(testPart));
    ok &= SLHook(scroller, @selector(drawRect:), (IMP)sl_drawRect, (IMP *)&SL_ORIG(drawRect));
    ok &= SLHook(scroller, @selector(drawKnob), (IMP)sl_drawKnob, (IMP *)&SL_ORIG(drawKnob));
    ok &= SLHook(scroller, @selector(drawKnobSlotInRect:highlight:), (IMP)sl_drawKnobSlot, (IMP *)&SL_ORIG(drawKnobSlot));
    ok &= SLHook(scroller, @selector(_old_drawArrow:highlightPart:), (IMP)sl_oldDrawArrow, (IMP *)&SL_ORIG(oldDrawArrow));
    ok &= SLHook(scroller, @selector(drawArrow:highlight:), (IMP)sl_drawArrowHighlight, (IMP *)&SL_ORIG(drawArrowHighlight));
    ok &= SLHook(scroller, @selector(highlight:), (IMP)sl_highlight, (IMP *)&SL_ORIG(highlight));
    ok &= SLHook(scroller, @selector(_windowChangedKeyState), (IMP)sl_windowChangedKeyState, (IMP *)&SL_ORIG(windowChangedKeyState));
    ok &= SLHook(scroller, @selector(wantsUpdateLayer), (IMP)sl_wantsUpdateLayer, (IMP *)&SL_ORIG(wantsUpdateLayer));
    ok &= SLHook(scroller, @selector(isOpaque), (IMP)sl_isOpaque, (IMP *)&SL_ORIG(isOpaque));
    ok &= SLHook(scroller, @selector(mouseDown:), (IMP)sl_mouseDown, (IMP *)&SL_ORIG(mouseDown));
    ok &= SLHook(scroller, NSSelectorFromString(@"_really_setLionScrollerStyle:"), (IMP)sl_reallySetStyle, (IMP *)&SL_ORIG(reallySetStyle));
    ok &= SLHook(scroller, @selector(setNeedsDisplay:), (IMP)sl_setNeedsDisplay, (IMP *)&SL_ORIG(setNeedsDisplay));
    ok &= SLHook(scroller, @selector(setNeedsDisplayInRect:), (IMP)sl_setNeedsDisplayInRect, (IMP *)&SL_ORIG(setNeedsDisplayInRect));
    SLHook(scroller, NSSelectorFromString(@"_setNeedsDisplayIfNotLayerBackedOverlayCompatible"), (IMP)sl_setNeedsDisplayIfNotLB, (IMP *)&SL_ORIG(setNeedsDisplayIfNotLB));
    SLHook(scroller, NSSelectorFromString(@"_setNeedsDisplayIfNotLayerBackedOverlayCompatibleInRect:"), (IMP)sl_setNeedsDisplayIfNotLBInRect, (IMP *)&SL_ORIG(setNeedsDisplayIfNotLBInRect));
    if (!ok) NSLog(@"SnowLeopardScrollBars: some NSScroller methods were missing; scroll bars may be incomplete.");

    SLHook(object_getClass(scroller), @selector(isCompatibleWithOverlayScrollers), (IMP)sl_isCompatibleWithOverlay, (IMP *)&SL_ORIG(isCompatibleWithOverlay));

    Class imp = NSClassFromString(@"NSScrollerImp");
    Class legacyImp = NSClassFromString(@"NSLegacyScrollerImp");
    if (imp) SLHook(imp, @selector(knobLength), (IMP)sl_impKnobLength, (IMP *)&SL_ORIG(impKnobLength));
    if (imp) SLHook(imp, @selector(setLayer:), (IMP)sl_impSetLayer, (IMP *)&SL_ORIG(impSetLayer));
    if (legacyImp) SLHook(legacyImp, @selector(knobEndInset), (IMP)sl_impKnobEndInset, (IMP *)&SL_ORIG(impKnobEndInset));

    gEnabled = YES;

    Class recommender = NSClassFromString(@"_NSScrollerStyleRecommender");
    if (recommender) {
        SLHook(recommender, @selector(recommendedScrollerStyle), (IMP)sl_recommendedStyle, (IMP *)&SL_ORIG(recommendedStyle));
        SEL setter = NSSelectorFromString(@"setRecommendedScrollerStyleAndNotify:");
        id shared = [recommender respondsToSelector:@selector(sharedScrollerStyleRecommender)]
                  ? [recommender performSelector:@selector(sharedScrollerStyleRecommender)] : nil;
        if (SLHook(recommender, setter, (IMP)sl_setRecommendedStyle, (IMP *)&SL_ORIG(setRecommendedStyle)) && shared) {
            // Store the effective style now, so a later change of setting is
            // seen as a change.
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(shared, setter, SL_ORIG(recommendedStyle)(shared, @selector(recommendedScrollerStyle)));
        }
    }

    // Press and hold on a scroll arrow in the window's resize corner.
    Class windowMeta = object_getClass([NSWindow class]);
    SEL hysteresis = NSSelectorFromString(@"_mouseHysteresisCheck:withExpiration:andDistance:finalMouseLocation:");
    Method check = class_getClassMethod([NSWindow class], hysteresis);
    if (check && !strcmp(method_getTypeEncoding(check), "q56@0:8@16@24{CGSize=dd}32^{CGPoint=dd}48") &&
        SLHook(windowMeta, hysteresis, (IMP)sl_hysteresisCheck, (IMP *)&SL_ORIG(hysteresisCheck))) {
        SLHook(object_getClass([NSEvent class]), @selector(startPeriodicEventsAfterDelay:withPeriod:),
               (IMP)sl_startPeriodicEvents, (IMP *)&SL_ORIG(startPeriodicEvents));
        SEL cursorUpdate = NSSelectorFromString(@"_edgeResizingCursorUpdate:atLocation:");
        Method update = class_getInstanceMethod([NSWindow class], cursorUpdate);
        if (update && !strcmp(method_getTypeEncoding(update), "c40@0:8@16{CGPoint=dd}24"))
            SLHook([NSWindow class], cursorUpdate, (IMP)sl_edgeResizingCursorUpdate, (IMP *)&SL_ORIG(edgeResizingCursorUpdate));
    }

    // Page scrollbars in WebKit (Safari's WebContent process, WebViews).
    SLWebKitInstall();

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                        selector:@selector(arrowVariantChanged:)
                                                            name:@"AppleAquaScrollBarVariantChanged"
                                                          object:nil
                                              suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    // Scrollers that already exist (when loaded late) were set up before we arrived.
    [self refreshAllScrollers];
}

/* Nothing is set up until the process has its application object. MIP can
   load the plugin before that exists: AppKit's open/save panel service, for
   one, checks in with Launch Services and then waits for a client before it
   creates NSApp and its window server connection. Using AppKit in between
   breaks that connection, and the service (TextEdit's save sheet) fails to
   start. So: with NSApp already there (normal applications, where MIP loads
   the plugin inside -[NSApplication init], or a late load), set up now;
   otherwise as soon as -[NSApplication init] returns. */
static id (*SL_ORIG(appInit))(id, SEL);

static id sl_appInit(id self, SEL _cmd)
{
    self = SL_ORIG(appInit)(self, _cmd);
    if (self && [NSThread isMainThread]) [SLScrollBars setUpScrollBars];
    return self;
}

+ (void)load
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (NSApp) {
        if ([NSThread isMainThread]) [self setUpScrollBars];
        else [self performSelectorOnMainThread:@selector(setUpScrollBars) withObject:nil waitUntilDone:NO];
    } else {
        SLHook([NSApplication class], @selector(init), (IMP)sl_appInit, (IMP *)&SL_ORIG(appInit));
    }
    [pool drain];
}

@end
