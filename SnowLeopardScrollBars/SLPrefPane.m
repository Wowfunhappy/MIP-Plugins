//
//  SLPrefPane.m
//  10.6's "Place scroll arrows:" setting, back in System Preferences' General
//  pane (Appearance.prefPane, class LookPref), below "Show scroll bars:" (on
//  which it depends) and above "Click in the scroll bar to:".
//
//  It works as 10.6's did (-[AppearanceShared scrollArrowVariant] and
//  -setScrollArrowVariant:, from its LookPref): AppleScrollBarVariant in the
//  global domain is "DoubleMax" for Together (the button with tag 1) and
//  "Single" for At top and bottom (tag 0); any other value but "DoubleBoth"
//  reads as Together, and "DoubleBoth" (both pairs, settable only with
//  `defaults`) selects neither. A change is written, synchronized, and
//  announced with the AppleAquaScrollBarVariantChanged distributed
//  notification, which every app with this plugin follows at once
//  (+[SLScrollBars arrowVariantChanged:]).
//
//  With overlay scroll bars, which have no arrows, it is disabled: whenever
//  AppKit's preferred scroller style is overlay ("Show scroll bars: When
//  scrolling", or "Automatically" where that gives overlay ones), followed
//  as it changes (NSPreferredScrollerStyleDidChangeNotification).
//
//  The control is a copy of the pane's own "Show scroll bars:" matrix and
//  label (so it has their font, size and style), retitled with 10.6's own
//  text in each of 10.6's languages (SLScrollArrows.strings, from 10.6's
//  LookPref.nib: extract.sh). The pane grows to make room: "Click in the scroll
//  bar to:" and everything below it move down.
//

#import "SLScrollBars.h"

static NSString *const kSLVariantKey = @"AppleScrollBarVariant";
static NSString *const kSLVariantChanged = @"AppleAquaScrollBarVariantChanged";

@interface SLArrowsPrefControl : NSObject {
    NSMatrix *_matrix;          // in the pane's view, which keeps them
    NSTextField *_label;
    NSColor *_labelColor;
}
@end

@implementation SLArrowsPrefControl

// 10.6's -scrollArrowVariant: 0 Single, 1 DoubleMax (and anything else), 2 DoubleBoth.
static NSInteger SLScrollArrowVariant(void)
{
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    NSString *value = [(id)CFPreferencesCopyAppValue((CFStringRef)kSLVariantKey, kCFPreferencesAnyApplication) autorelease];
    if (![value isKindOfClass:[NSString class]]) return 1;
    if ([value isEqualToString:@"Single"]) return 0;
    if ([value isEqualToString:@"DoubleBoth"]) return 2;
    return 1;
}

- (id)initWithMatrix:(NSMatrix *)matrix label:(NSTextField *)label
{
    if ((self = [super init])) {
        _matrix = matrix;
        _label = label;
        _labelColor = [[label textColor] retain];
        [_matrix setTarget:self];
        [_matrix setAction:@selector(placeScrollArrowsChanged:)];
        [self update:nil];
        [self styleChanged:nil];
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(update:)
                                                                name:kSLVariantChanged object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(styleChanged:)
                                                     name:NSPreferredScrollerStyleDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_labelColor release];
    [super dealloc];
}

// Overlay scroll bars have no arrows to place.
- (void)styleChanged:(NSNotification *)note
{
    BOOL arrows = [NSScroller preferredScrollerStyle] == NSScrollerStyleLegacy;
    [_matrix setEnabled:arrows];
    [_label setTextColor:arrows ? _labelColor : [NSColor disabledControlTextColor]];
}

- (void)update:(NSNotification *)note
{
    NSInteger variant = SLScrollArrowVariant();
    if (variant == 2) {
        [_matrix setAllowsEmptySelection:YES];
        [_matrix deselectAllCells];
    } else {
        [_matrix selectCellWithTag:variant];
        [_matrix setAllowsEmptySelection:NO];
    }
}

// 10.6's -setScrollArrowVariant:.
- (void)placeScrollArrowsChanged:(NSMatrix *)sender
{
    NSInteger variant = [sender selectedTag];
    if (variant != 0 && variant != 1) return;
    [sender setAllowsEmptySelection:NO];
    if (variant == SLScrollArrowVariant()) return;
    CFPreferencesSetAppValue((CFStringRef)kSLVariantKey, variant == 1 ? CFSTR("DoubleMax") : CFSTR("Single"),
                             kCFPreferencesAnyApplication);
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kSLVariantChanged object:nil
                                                                 userInfo:nil deliverImmediately:YES];
}

@end

static id SLIvar(id object, const char *name)
{
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// A copy of a view (with its cells, font, style), through archiving.
static id SLCopyView(NSView *view)
{
    return [NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:view]];
}

// A matrix's label: the static text just left of it, beside its first row
// (the label may run to two lines, ending beside the first row).
static NSTextField *SLLabelFor(NSMatrix *matrix)
{
    NSRect c = [matrix frame];
    NSRect firstRow = NSMakeRect(NSMinX(c), NSMaxY(c) - [matrix cellSize].height, NSWidth(c), [matrix cellSize].height);
    NSTextField *best = nil;
    CGFloat bestOverlap = 0;
    for (NSView *view in [[matrix superview] subviews]) {
        if (![view isKindOfClass:[NSTextField class]] || [(NSTextField *)view isEditable]) continue;
        NSRect f = [view frame];
        if (NSMaxX(f) > NSMinX(c) + 2 || NSMinX(c) - NSMaxX(f) > 30) continue;
        CGFloat overlap = MIN(NSMaxY(f), NSMaxY(firstRow)) - MAX(NSMinY(f), NSMinY(firstRow));
        if (overlap > bestOverlap) { best = (NSTextField *)view; bestOverlap = overlap; }
    }
    return best;
}

static NSString *SLText(NSString *key)
{
    return [[NSBundle bundleForClass:objc_getClass("SLScrollBars")] localizedStringForKey:key value:nil table:@"SLScrollArrows"];
}

static void (*orig_mainViewDidLoad)(id, SEL);

static void sl_mainViewDidLoad(id self, SEL _cmd)
{
    orig_mainViewDidLoad(self, _cmd);

    NSMatrix *show = SLIvar(self, "showScrollBarsMatrix");
    NSMatrix *click = SLIvar(self, "clickScrollbarMatrix");
    NSView *pane = [show superview];
    NSTextField *showLabel = SLLabelFor(show), *clickLabel = SLLabelFor(click);
    if (![show isKindOfClass:[NSMatrix class]] || ![click isKindOfClass:[NSMatrix class]] || !showLabel || !clickLabel || [show numberOfRows] < 2) return;

    // A matrix like "Show scroll bars:", two rows, with 10.6's buttons in 10.6's order.
    NSMatrix *matrix = SLCopyView(show);
    NSTextField *label = SLCopyView(showLabel);
    [matrix renewRows:2 columns:1];
    NSButtonCell *together = [matrix cellAtRow:0 column:0], *apart = [matrix cellAtRow:1 column:0];
    [together setTitle:SLText(@"DoubleMax")];
    [together setTag:1];
    [apart setTitle:SLText(@"Single")];
    [apart setTag:0];
    [matrix sizeToCells];
    [label setStringValue:SLText(@"Place scroll arrows:")];
    // As wide as the widest label in the column (it ends where they do), and
    // wrapping beyond that, as they do.
    CGFloat column = 0;
    for (NSView *view in [pane subviews])
        if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable]
            && fabs(NSMaxX([view frame]) - NSMaxX([showLabel frame])) < 1)
            column = MAX(column, NSWidth([view frame]));
    [[label cell] setWraps:YES];
    [label setPreferredMaxLayoutWidth:column];

    // The pane is laid out with constraints, measured from the top down, and
    // each language's nib ties "Click in the scroll bar to:" to what's above
    // it in its own way. So: every vertical constraint between something above
    // the top of "Click in the scroll bar to:" (its label or matrix, whichever
    // is higher; the pane's top counts as above) and something at or below it
    // is lengthened by the new pair's height, opening a gap of exactly that
    // much there, and the pair is placed in the gap below "Show scroll bars:",
    // spaced from it as "Click in the scroll bar to:" is. The pane grows by as
    // much. (Its view isn't in the window yet: System Preferences sizes the
    // window to it afterwards.)
    if (pane != ((NSView *(*)(id, SEL))objc_msgSend)(self, sel_registerName("mainView"))) return;     // (NSPreferencePane)
    CGFloat gap = NSMinY([show frame]) - NSMaxY([click frame]);
    CGFloat rise = NSHeight([matrix frame]) + gap;
    CGFloat paneTop = NSMaxY([pane bounds]);
    CGFloat showTop = paneTop - NSMaxY([show frame]), labelTop = paneTop - NSMaxY([showLabel frame]);    // from the top
    // Where the "Show scroll bars:" label's text ends (its last line is beside
    // the first row): its frame may be taller than its text (German's).
    CGFloat textHeight = [[showLabel cell] cellSizeForBounds:NSMakeRect(0, 0, NSWidth([showLabel frame]), CGFLOAT_MAX)].height;
    CGFloat labelBottom = labelTop + MIN(textHeight, NSHeight([showLabel frame]));
    CGFloat clickTop = paneTop - NSMaxY([click frame]), clickLabelTop = paneTop - NSMaxY([clickLabel frame]);
    CGFloat line = MIN(clickTop, clickLabelTop) - 0.5;
    BOOL (^below)(id, NSLayoutAttribute, BOOL *) = ^BOOL(id item, NSLayoutAttribute attribute, BOOL *known) {
        *known = YES;
        if (item == pane) {
            if (attribute == NSLayoutAttributeTop) return NO;
            if (attribute == NSLayoutAttributeBottom) return YES;
            *known = NO;
            return NO;
        }
        if (![item isKindOfClass:[NSView class]] || [item superview] != pane) { *known = NO; return NO; }
        return paneTop - NSMaxY([item frame]) >= line;
    };
    for (NSLayoutConstraint *c in [pane constraints]) {
        NSLayoutAttribute a1 = [c firstAttribute], a2 = [c secondAttribute];
        BOOL vertical1 = (a1 == NSLayoutAttributeTop || a1 == NSLayoutAttributeBottom || a1 == NSLayoutAttributeCenterY || a1 == NSLayoutAttributeBaseline);
        BOOL vertical2 = (a2 == NSLayoutAttributeTop || a2 == NSLayoutAttributeBottom || a2 == NSLayoutAttributeCenterY || a2 == NSLayoutAttributeBaseline);
        if (!vertical1 || !vertical2 || ![c secondItem] || [c multiplier] != 1) continue;
        BOOL known1, known2;
        BOOL below1 = below([c firstItem], a1, &known1), below2 = below([c secondItem], a2, &known2);
        if (!known1 || !known2 || below1 == below2) continue;
        // first = second + constant, measured downwards: lengthen it.
        [c setConstant:[c constant] + (below1 ? rise : -rise)];
    }

    // The copies keep their originals' sizes as constraints of their own:
    // the label takes its text's size instead, the matrix its two rows'.
    [matrix removeConstraints:[matrix constraints]];
    [label removeConstraints:[label constraints]];
    [matrix setTranslatesAutoresizingMaskIntoConstraints:NO];
    [label setTranslatesAutoresizingMaskIntoConstraints:NO];
    [pane addSubview:label];
    [pane addSubview:matrix];
    NSArray *added = @[
        [NSLayoutConstraint constraintWithItem:matrix attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual
                                        toItem:show attribute:NSLayoutAttributeBottom multiplier:1 constant:gap],
        // (Its last line beside the first row, as the "Show scroll bars:" label's is;
        // the copy's frame is its text's size.)
        [NSLayoutConstraint constraintWithItem:label attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual
                                        toItem:matrix attribute:NSLayoutAttributeTop multiplier:1 constant:labelBottom - showTop],
        [NSLayoutConstraint constraintWithItem:label attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual
                                        toItem:showLabel attribute:NSLayoutAttributeTrailing multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:matrix attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual
                                        toItem:show attribute:NSLayoutAttributeLeading multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:matrix attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual
                                        toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:NSWidth([matrix frame])],
        [NSLayoutConstraint constraintWithItem:matrix attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual
                                        toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:NSHeight([matrix frame])],
    ];
    [pane addConstraints:added];
    [pane setFrameSize:NSMakeSize(NSWidth([pane frame]), NSHeight([pane frame]) + rise)];

    // Keyboard and VoiceOver, as for its neighbours: after "Show scroll bars:".
    [matrix setNextKeyView:[show nextKeyView]];
    [show setNextKeyView:matrix];
    [matrix accessibilitySetOverrideValue:label forAttribute:NSAccessibilityTitleUIElementAttribute];

    // Kept for the pane's lifetime (the pane object keeps its view).
    objc_setAssociatedObject(self, &orig_mainViewDidLoad, [[[SLArrowsPrefControl alloc] initWithMatrix:matrix label:label] autorelease],
                             OBJC_ASSOCIATION_RETAIN);
}

static BOOL SLPrefPaneHook(void)
{
    static BOOL done = NO;
    if (done) return YES;
    Class cls = NSClassFromString(@"LookPref");
    if (!cls || ![[[NSBundle bundleForClass:cls] bundleIdentifier] isEqualToString:@"com.apple.preference.general"]) return NO;
    done = SLHook(cls, @selector(mainViewDidLoad), (IMP)sl_mainViewDidLoad, (IMP *)&orig_mainViewDidLoad);
    return YES;
}

@interface SLPrefPaneWatcher : NSObject
@end
@implementation SLPrefPaneWatcher
+ (void)bundleDidLoad:(NSNotification *)note
{
    if (SLPrefPaneHook()) [[NSNotificationCenter defaultCenter] removeObserver:self name:NSBundleDidLoadNotification object:nil];
}
@end

void SLPrefPaneInstall(void)
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.systempreferences"]) return;
    // The General pane's code is loaded when the pane is first shown.
    if (!SLPrefPaneHook())
        [[NSNotificationCenter defaultCenter] addObserver:[SLPrefPaneWatcher class] selector:@selector(bundleDidLoad:)
                                                     name:NSBundleDidLoadNotification object:nil];
}
