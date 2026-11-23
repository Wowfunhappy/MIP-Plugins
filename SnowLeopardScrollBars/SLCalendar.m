//
//  SLCalendar.m
//  Calendar's Day and Week views with Snow Leopard scroll bars.
//
//  Calendar (com.apple.iCal) lays its timeline out for overlay scrollers: the
//  canvas stops 12 points short of the window's right edge, and the timeline,
//  the all-day row and the day-name header are three stacked scroll views,
//  each with a vertical scroller. With legacy scroll bars that reads as a
//  scroll bar floating in from the edge, with two thumbless stubs above it.
//
//  So, in a Day or Week view (CalUIDayContentView / CalUIWeekContentView):
//   - the timeline's vertical scroller (the lowest of the stacked
//     InfiniteSwipeControllerScrollViews) is moved into the content view,
//     flush right and the content view's full height, from the bottom of the
//     window to the toolbar (it stays the scroll view's scroller);
//   - the other two scroll views' vertical scrollers are hidden.
//  Calendar's own layout is left as it is, so the grid and its events keep
//  Calendar's 12-point margin, now between them and the scroll bar. The
//  month/date heading above (a CalUIFontSmoothedTextLayer, or its subclass
//  CalUISizeBasedDateContentsTextLayer in the Day view, directly in the
//  content view's layer, right-aligned by Calendar near the window's edge)
//  is moved left so its right edge lines up with the grid's.
//  With overlay scrollers everything is left (or put back) as Calendar has it.
//

#import "SLScrollBars.h"
#import <QuartzCore/QuartzCore.h>

static void (*orig_cal_tile)(id, SEL);

static Class gSwipeScrollView, gHeadingLayer;
static void (*orig_heading_setPosition)(id, SEL, CGPoint);
static void (*orig_heading_setBounds)(id, SEL, CGRect);
static void (*orig_heading_setFrame)(id, SEL, CGRect);
static char kSLGridRight;           // per content view: where the grid ends (content view coordinates)

static BOOL SLCalendarUsesLegacyScrollers(void)
{
    return SLIsEnabled() && [NSScroller preferredScrollerStyle] == NSScrollerStyleLegacy;
}

// The Day or Week content view a view is in, if any.
static NSView *SLCalendarContentView(NSView *view)
{
    for (; view; view = [view superview]) {
        NSString *name = NSStringFromClass([view class]);
        if ([name isEqualToString:@"CalUIDayContentView"] || [name isEqualToString:@"CalUIWeekContentView"]) return view;
    }
    return nil;
}

// Puts the heading's right edge on the grid's, if this is a content view's heading.
static void SLCalendarAlignHeading(CALayer *heading)
{
    id delegate = [[heading superlayer] delegate];
    if (![delegate isKindOfClass:[NSView class]] || SLCalendarContentView(delegate) != delegate) return;
    NSNumber *gridRight = SLCalendarUsesLegacyScrollers() ? objc_getAssociatedObject(delegate, &kSLGridRight) : nil;
    if (!gridRight) return;
    CGFloat dx = [gridRight doubleValue] - CGRectGetMaxX([heading frame]);
    if (fabs(dx) < 0.25) return;
    CGPoint position = [heading position];
    orig_heading_setPosition(heading, @selector(setPosition:), CGPointMake(position.x + dx, position.y));
}

static void sl_heading_setPosition(CALayer *self, SEL _cmd, CGPoint position)
{
    orig_heading_setPosition(self, _cmd, position);
    SLCalendarAlignHeading(self);
}

static void sl_heading_setBounds(CALayer *self, SEL _cmd, CGRect bounds)
{
    orig_heading_setBounds(self, _cmd, bounds);
    SLCalendarAlignHeading(self);
}

static void sl_heading_setFrame(CALayer *self, SEL _cmd, CGRect frame)
{
    orig_heading_setFrame(self, _cmd, frame);
    SLCalendarAlignHeading(self);
}

static void SLCalendarArrange(NSScrollView *scrollView)
{
    NSView *content = SLCalendarContentView(scrollView);
    NSScroller *scroller = [scrollView verticalScroller];
    if (!content || !scroller) return;

    if (!SLCalendarUsesLegacyScrollers()) {
        // Overlay scrollers: Calendar's own layout (the heading goes back at
        // Calendar's next layout of it).
        objc_setAssociatedObject(content, &kSLGridRight, nil, OBJC_ASSOCIATION_RETAIN);
        if ([scroller superview] != scrollView) {
            [scrollView addSubview:scroller];
            [scrollView tile];
        }
        return;
    }

    // The timeline is the lowest of the stacked scroll views.
    NSView *container = [scrollView superview];
    BOOL flipped = [container isFlipped];
    BOOL timeline = YES;
    for (NSView *other in [container subviews]) {
        if (other == scrollView || ![other isKindOfClass:gSwipeScrollView]) continue;
        if (flipped ? NSMaxY([other frame]) > NSMaxY([scrollView frame]) : NSMinY([other frame]) < NSMinY([scrollView frame]))
            timeline = NO;
    }
    if (!timeline) {
        [scroller setHidden:YES];       // under the timeline's full-height scroller
        return;
    }

    // Where the grid ends, for the heading.
    NSRect grid = [content convertRect:[[scrollView contentView] frame] fromView:scrollView];
    objc_setAssociatedObject(content, &kSLGridRight, @(NSMaxX(grid)), OBJC_ASSOCIATION_RETAIN);
    if (gHeadingLayer) {
        for (CALayer *layer in [[[content layer] sublayers] copy])
            if ([layer isKindOfClass:gHeadingLayer]) SLCalendarAlignHeading(layer);
    }

    if ([scroller superview] != content) [content addSubview:scroller];
    NSRect bounds = [content bounds];
    CGFloat width = [NSScroller scrollerWidthForControlSize:[scroller controlSize] scrollerStyle:NSScrollerStyleLegacy];
    NSRect frame = NSMakeRect(NSMaxX(bounds) - width, NSMinY(bounds), width, NSHeight(bounds));
    if (!NSEqualRects([scroller frame], frame)) [scroller setFrame:frame];
}

static void sl_cal_tile(NSScrollView *self, SEL _cmd)
{
    orig_cal_tile(self, _cmd);
    SLCalendarArrange(self);
}

void SLCalendarInstall(void)
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.iCal"]) return;
    gSwipeScrollView = NSClassFromString(@"InfiniteSwipeControllerScrollView");
    if (!gSwipeScrollView || ![gSwipeScrollView isSubclassOfClass:[NSScrollView class]]) return;
    SLHook(gSwipeScrollView, @selector(tile), (IMP)sl_cal_tile, (IMP *)&orig_cal_tile);

    gHeadingLayer = NSClassFromString(@"CalUIFontSmoothedTextLayer");
    if (gHeadingLayer && [gHeadingLayer isSubclassOfClass:[CALayer class]] &&
        SLHook(gHeadingLayer, @selector(setPosition:), (IMP)sl_heading_setPosition, (IMP *)&orig_heading_setPosition)) {
        SLHook(gHeadingLayer, @selector(setBounds:), (IMP)sl_heading_setBounds, (IMP *)&orig_heading_setBounds);
        SLHook(gHeadingLayer, @selector(setFrame:), (IMP)sl_heading_setFrame, (IMP *)&orig_heading_setFrame);
    } else {
        gHeadingLayer = nil;
    }
}
