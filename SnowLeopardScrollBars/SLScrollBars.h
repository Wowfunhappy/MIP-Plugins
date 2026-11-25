//
//  SLScrollBars.h
//  Snow Leopard scroll bars for Mavericks (SIMBL plugin).
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Built with -fobjc-gc (build.sh), so it runs in apps that use garbage
// collection as well as in the rest. Under GC, -retain, -release and -dealloc
// do nothing, and the compiler's write barriers keep alive what globals and
// ivars hold. Two things need care: a CF object created +1 is handed to
// Objective-C with CFBridgingRelease (under GC, -autorelease wouldn't release
// it), and an observer is kept referenced (under GC the notification center
// holds it weakly).

// ---- SLArt.m -------------------------------------------------------------

// Theme "kinds" used by AppKit 1038 for scroll bar art.
enum {
    kSLKindTrack        = 0x32,   // small: 0xfa
    kSLKindArrowSingle  = 0x33,   // small: 0xfb
    kSLKindThumb        = 0x34,   // small: 0xfc
    kSLKindEndCap       = 0x35,   // small: 0xfd
    kSLKindArrowDouble  = 0x36,   // small: 0xfe
};

BOOL SLArtLoad(void);
CGImageRef SLThemeImage(int kind, int state, int dir, int tint, int index, BOOL pattern);
NSSize SLImageSize(CGImageRef image);
void SLDrawImagePart(CGImageRef image, NSRect src, NSRect dst, BOOL flipped);
void SLDrawImageAtPoint(CGImageRef image, NSPoint point, BOOL flipped);
void SLTileImage(CGImageRef image, NSRect rect, NSPoint offset, BOOL flipped);
void SLDrawThreePart(CGImageRef caps, CGImageRef fill, NSRect rect, BOOL vertical, BOOL flipped);

// ---- SLDraw.m ------------------------------------------------------------

// ___NSScrollerArrowConfig values (0 = no arrows).
enum {
    kSLArrowsSingle     = 1,
    kSLArrowsDoubleMin  = 2,
    kSLArrowsDoubleMax  = 3,
    kSLArrowsDoubleBoth = 4,
};

typedef struct {
    NSRect    bounds;
    BOOL      horizontal;
    BOOL      small;
    BOOL      enabled;
    BOOL      flipped;          // drawing/view coordinates are flipped
    int       config;           // arrow configuration; 0 = no arrows
    CGFloat   thickness;        // 15 regular, 11 small
    double    value;            // 0...1
    double    proportion;       // knob proportion, 0...1
    BOOL      active;           // window has active controls (thumb)
    BOOL      arrowsActive;     // ...or is the main window (arrows)
    NSControlTint tint;
    NSInteger pressedArrow;     // NSScrollerDecrementArrow, NSScrollerIncrementArrow, or -1
    BOOL      pressedInMaxEnd;  // DoubleBoth: the pressed arrow is in the far pair
    BOOL      webKitMetrics;    // size the knob like WebCore does
    BOOL      fullLengthSlot;   // no arrows in the model: the knob travels the whole length
} SLState;

CGFloat SLMinimumKnobLength(BOOL small);
NSUsableScrollerParts SLUsableParts(const SLState *st);
void SLSlotSpan(const SLState *st, CGFloat *start, CGFloat *length);
NSRect SLDrawingRect(const SLState *st, NSScrollerPart part);
NSRect SLHitRect(const SLState *st, NSScrollerPart part);
NSScrollerPart SLHitTest(const SLState *st, NSPoint pointInScroller);
void SLPaintSlot(const SLState *st, NSRect rect);
void SLPaintKnob(const SLState *st);
void SLPaintArrow(const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart);
NSInteger SLHighlightPartForEnd(const SLState *st, BOOL nearEnd);
void SLPaintAll(const SLState *st);

// ---- SLScrollBars.m --------------------------------------------------------

int SLArrowConfig(void);            // from AppleScrollBarVariant
BOOL SLIsEnabled(void);             // the plugin is active in this process
BOOL SLHook(Class cls, SEL sel, IMP replacement, IMP *original);

// ---- SLWebKit.m ------------------------------------------------------------

void SLWebKitInstall(void);

// ---- SLCalendar.m ----------------------------------------------------------

void SLCalendarInstall(void);       // Calendar's Day and Week views

// ---- SLSkinned.m -----------------------------------------------------------

void SLSkinnedInstall(void);
void SLCarbonInstall(void);           // Carbon (HIToolbox) scroll bars (SLCarbon.m)
void SLPrefPaneInstall(void);         // System Preferences: 10.6's "Place scroll arrows:" (SLPrefPane.m)
BOOL SLLionSkin(NSScroller *scroller);             // an app's own skin, made for Lion's arrowless scroll bars
BOOL SLProKitScroller(NSScroller *scroller);       // ProKit's: it draws, with 10.6's geometry
BOOL SLSkinHandled(NSScroller *scroller);          // ...one this plugin gives 10.6's ends (Reminders')
void SLSkinnedPaintArrow(NSScroller *scroller, const SLState *st, NSScrollerArrow arrow, NSInteger highlightPart);
NSRect SLSkinnedEndRect(const SLState *st, NSScrollerArrow arrow);   // an end and its fade: all SLSkinnedPaintArrow paints
void SLSkinnedDrawKnob(NSScroller *scroller, const SLState *st);
