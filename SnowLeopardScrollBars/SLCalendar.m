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
//  Calendar's 12-point margin, now between them and the scroll bar.
//  With overlay scrollers everything is left (or put back) as Calendar has it.
//

#import "SLScrollBars.h"

static void (*orig_cal_tile)(id, SEL);

static Class gSwipeScrollView;

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

static void SLCalendarArrange(NSScrollView *scrollView)
{
    NSView *content = SLCalendarContentView(scrollView);
    NSScroller *scroller = [scrollView verticalScroller];
    if (!content || !scroller) return;

    if (!SLCalendarUsesLegacyScrollers()) {
        // Overlay scrollers: Calendar's own layout.
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
}
