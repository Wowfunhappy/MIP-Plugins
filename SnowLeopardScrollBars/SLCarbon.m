//
//  SLCarbon.m
//  Carbon scroll bars (HIToolbox's HIScrollBar; Fetch 5, for one) as on 10.6.
//
//  HIToolbox still has its 10.6 scroll bars: it reads AppleScrollBarVariant
//  (and follows AppleAquaScrollBarVariantChanged) for the arrow style, lays
//  the arrows out, hit-tests them, and draws them from the theme's art in
//  Extras2.rsrc - the same 10.6 art the rest of this plugin uses. Each of its
//  theme functions first asks _HIThemeUseCoreUI(), though, and on Mavericks
//  that says yes (the AppleUseCoreUI preference, on by default, and always on
//  Retina displays), so scroll bars are drawn, laid out and hit-tested by
//  CoreUI instead: Mavericks' arrowless legacy scroll bar.
//
//  With 10.6's scroll bars, _HIThemeUseCoreUI() answers no inside HIToolbox's
//  theme functions for a scroll bar track - drawing, hit-testing, bounds,
//  part bounds, thumb position and shape, live value, drag rectangle - so
//  all of a scroll bar takes HIToolbox's 10.6 path together, and nothing
//  else (sliders, progress bars, buttons) changes. With overlay scroll bars
//  HIToolbox is left as it is. This is set up as soon as the plugin loads
//  (+[SLScrollBars load]): a Carbon app never creates NSApp, and may not have
//  AppKit at all - the plugin is listed for apps with HIToolbox too.
//
//  HIToolbox's 10.6 drawing is made for 1x: it stretches and tiles 1x
//  bitmaps, and drawn straight into a Retina display's 2x context they
//  interpolate into seams down the track and through the thumb. There it
//  draws into a 1x bitmap instead, shown with its pixels doubled, as a 10.6
//  app's scroll bars were on a Retina display.
//

#import "SLScrollBars.h"
#import <Carbon/Carbon.h>
#import <dlfcn.h>

typedef void (*SLHookFn)(void *symbol, void *replacement, void **original);
typedef void *(*SLFindSymbolFn)(const void *image, const char *name);
typedef const void *(*SLGetImageFn)(const char *name);

// How deep this thread is in HIToolbox's theme code for a scroll bar.
static __thread int gScrollBarDepth;

// As for AppKit's scroll bars: when AppKit's scroller style is the classic
// (legacy) one. Carbon's scroll bars are always classic, but with overlay
// scroll bars everywhere else ("When scrolling", or "Automatically" with a
// trackpad) they are left as Mavericks draws them. (AppKit is loaded with the
// plugin, so it can be asked even in a Carbon app without NSApp.)
static BOOL SLCarbonSnowLeopard(void)
{
    return [NSScroller preferredScrollerStyle] == NSScrollerStyleLegacy;
}

static Boolean (*orig_useCoreUI)(void);

static Boolean sl_useCoreUI(void)
{
    if (gScrollBarDepth > 0 && SLCarbonSnowLeopard()) return false;
    return orig_useCoreUI();
}

static inline BOOL SLIsScrollBarKind(const HIThemeTrackDrawInfo *info)
{
    if (!info) return NO;
    ThemeTrackKind kind = info->kind;
    return kind == kThemeScrollBarMedium || kind == kThemeScrollBarSmall || kind == kThemeScrollBarMini;
}

// Wrappers: each marks the call as a scroll bar's (always, or when its track
// is a scroll bar) for _HIThemeUseCoreUI.
#define SL_IN(cond)   BOOL in_ = (cond); if (in_) gScrollBarDepth++;
#define SL_OUT        if (in_) gScrollBarDepth--;

static OSStatus (*orig_drawTrack)(const HIThemeTrackDrawInfo *, const HIRect *, CGContextRef, HIThemeOrientation);
static OSStatus sl_drawTrack(const HIThemeTrackDrawInfo *info, const HIRect *ghost, CGContextRef ctx, HIThemeOrientation o)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_drawTrack(info, ghost, ctx, o); SL_OUT return r; }

static OSStatus (*orig_trackBounds)(const HIThemeTrackDrawInfo *, HIRect *);
static OSStatus sl_trackBounds(const HIThemeTrackDrawInfo *info, HIRect *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_trackBounds(info, out); SL_OUT return r; }

static OSStatus (*orig_partBounds)(const HIThemeTrackDrawInfo *, ControlPartCode, HIRect *);
static OSStatus sl_partBounds(const HIThemeTrackDrawInfo *info, ControlPartCode part, HIRect *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_partBounds(info, part, out); SL_OUT return r; }

static OSStatus (*orig_thumbFromBounds)(const HIThemeTrackDrawInfo *, const HIRect *, CGFloat *);
static OSStatus sl_thumbFromBounds(const HIThemeTrackDrawInfo *info, const HIRect *bounds, CGFloat *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_thumbFromBounds(info, bounds, out); SL_OUT return r; }

static OSStatus (*orig_thumbFromOffset)(const HIThemeTrackDrawInfo *, const HIPoint *, CGFloat *);
static OSStatus sl_thumbFromOffset(const HIThemeTrackDrawInfo *info, const HIPoint *offset, CGFloat *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_thumbFromOffset(info, offset, out); SL_OUT return r; }

static OSStatus (*orig_liveValue)(const HIThemeTrackDrawInfo *, CGFloat, SInt32 *);
static OSStatus sl_liveValue(const HIThemeTrackDrawInfo *info, CGFloat position, SInt32 *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_liveValue(info, position, out); SL_OUT return r; }

static OSStatus (*orig_dragRect)(const HIThemeTrackDrawInfo *, HIRect *);
static OSStatus sl_dragRect(const HIThemeTrackDrawInfo *info, HIRect *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_dragRect(info, out); SL_OUT return r; }

static OSStatus (*orig_thumbShape)(const HIThemeTrackDrawInfo *, HIShapeRef *);
static OSStatus sl_thumbShape(const HIThemeTrackDrawInfo *info, HIShapeRef *out)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_thumbShape(info, out); SL_OUT return r; }

static Boolean (*orig_hitTestTrack)(const HIThemeTrackDrawInfo *, const HIPoint *, ControlPartCode *);
static Boolean sl_hitTestTrack(const HIThemeTrackDrawInfo *info, const HIPoint *point, ControlPartCode *out)
{ SL_IN(SLIsScrollBarKind(info)) Boolean r = orig_hitTestTrack(info, point, out); SL_OUT return r; }

static Boolean (*orig_hitTestArrows)(const HIRect *, const HIScrollBarTrackInfo *, Boolean, const HIPoint *, HIRect *, ControlPartCode *);
static Boolean sl_hitTestArrows(const HIRect *bounds, const HIScrollBarTrackInfo *info, Boolean horizontal, const HIPoint *point, HIRect *track, ControlPartCode *out)
{ SL_IN(YES) Boolean r = orig_hitTestArrows(bounds, info, horizontal, point, track, out); SL_OUT return r; }

static OSStatus (*orig_scrollBarTrackRect)(const HIRect *, const HIScrollBarTrackInfo *, Boolean, HIRect *);
static OSStatus sl_scrollBarTrackRect(const HIRect *bounds, const HIScrollBarTrackInfo *info, Boolean horizontal, HIRect *out)
{ SL_IN(YES) OSStatus r = orig_scrollBarTrackRect(bounds, info, horizontal, out); SL_OUT return r; }

// HIToolbox's own internal scroll bar functions (HIScrollBar calls some of them directly).
static OSStatus (*orig_drawScrollBar)(const HIThemeTrackDrawInfo *, const CGRect *, void *, void *, CGContextRef);
// In a context scaled above 1x (a Retina display's), into a 1x bitmap of the
// track's bounds, then into the context with each pixel doubled. HIToolbox
// draws its scroll bars in unflipped (y up) coordinates, having unflipped the
// views' contexts; the bitmap is the same.
static OSStatus SLDrawScrollBarAt1x(const HIThemeTrackDrawInfo *info, const CGRect *ghost, void *erase, void *refcon, CGContextRef ctx)
{
    CGRect bounds = CGRectIntegral(info->bounds);
    size_t width = (size_t)bounds.size.width, height = (size_t)bounds.size.height;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = (width && height)
        ? CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host) : NULL;
    CGColorSpaceRelease(space);
    if (!bitmap) return orig_drawScrollBar(info, ghost, erase, refcon, ctx);
    CGContextTranslateCTM(bitmap, -bounds.origin.x, -bounds.origin.y);
    OSStatus result = orig_drawScrollBar(info, ghost, erase, refcon, bitmap);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);

    CGContextSaveGState(ctx);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    if (CGContextGetCTM(ctx).d < 0) {           // a flipped context: draw the image upright
        CGContextTranslateCTM(ctx, 0, 2 * CGRectGetMinY(bounds) + bounds.size.height);
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextDrawImage(ctx, bounds, image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
    return result;
}

static OSStatus sl_drawScrollBar(const HIThemeTrackDrawInfo *info, const CGRect *ghost, void *erase, void *refcon, CGContextRef ctx)
{
    SL_IN(YES)
    OSStatus r;
    CGSize unit = ctx ? CGContextConvertSizeToDeviceSpace(ctx, CGSizeMake(1, 1)) : CGSizeMake(1, 1);
    if (info && ctx && SLCarbonSnowLeopard() && MAX(fabs(unit.width), fabs(unit.height)) > 1.01)
        r = SLDrawScrollBarAt1x(info, ghost, erase, refcon, ctx);
    else
        r = orig_drawScrollBar(info, ghost, erase, refcon, ctx);
    SL_OUT
    return r;
}

static Boolean (*orig_hitTestScrollBar)(const HIThemeTrackDrawInfo *, CGPoint, short *);
static Boolean sl_hitTestScrollBar(const HIThemeTrackDrawInfo *info, CGPoint point, short *out)
{ SL_IN(YES) Boolean r = orig_hitTestScrollBar(info, point, out); SL_OUT return r; }

static OSStatus (*orig_scrollBarDragBounds)(const HIThemeTrackDrawInfo *, CGRect *);
static OSStatus sl_scrollBarDragBounds(const HIThemeTrackDrawInfo *info, CGRect *out)
{ SL_IN(YES) OSStatus r = orig_scrollBarDragBounds(info, out); SL_OUT return r; }

static OSStatus (*orig_thumbRegion)(const HIThemeTrackDrawInfo *, RgnHandle);
static OSStatus sl_thumbRegion(const HIThemeTrackDrawInfo *info, RgnHandle rgn)
{ SL_IN(SLIsScrollBarKind(info)) OSStatus r = orig_thumbRegion(info, rgn); SL_OUT return r; }

#if !__LP64__
// Every view, not just the window's root: HIToolbox redraws a view from its
// drawing cache unless the view itself is marked (HIView::DrawCacheOrSelf).
static void SLCarbonRedraw(HIViewRef view)
{
    if (!view) return;
    HIViewSetNeedsDisplay(view, true);
    for (HIViewRef sub = HIViewGetFirstSubview(view); sub; sub = HIViewGetNextView(sub)) SLCarbonRedraw(sub);
}
#endif

void SLCarbonInstall(void)
{
    SLHookFn hook = (SLHookFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    SLFindSymbolFn find = (SLFindSymbolFn)dlsym(RTLD_DEFAULT, "MSFindSymbol");
    SLGetImageFn image = (SLGetImageFn)dlsym(RTLD_DEFAULT, "MSGetImageByName");
    const void *hitoolbox = image ? image("/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox") : NULL;
    if (!hook || !find || !hitoolbox) return;

    // Its private functions, by symbol (they differ in name between i386 and x86_64).
#if __LP64__
    const char *drawScrollBar = "__Z21_HIThemeDrawScrollBarPK20HIThemeTrackDrawInfoPK6CGRectP14ThemeEraseXUPPPvP9CGContext";
#else
    const char *drawScrollBar = "__Z21_HIThemeDrawScrollBarPK20HIThemeTrackDrawInfoPK6CGRectP14ThemeEraseXUPPmP9CGContext";
#endif
    void *useCoreUI = find(hitoolbox, "__HIThemeUseCoreUI");
    void *drawSB = find(hitoolbox, drawScrollBar);
    void *hitSB = find(hitoolbox, "__Z24_HIThemeHitTestScrollBarPK20HIThemeTrackDrawInfo7CGPointPs");
    void *dragSB = find(hitoolbox, "__Z23_GetScrollBarDragBoundsPK20HIThemeTrackDrawInfoP6CGRect");
    void *thumbRgn = find(hitoolbox, "__HIThemeGetTrackThumbRegion");
    // All of them, or none: a scroll bar half on each path would draw one
    // layout and hit-test another.
    if (!useCoreUI || !drawSB || !hitSB || !dragSB || !thumbRgn) return;

    struct { const char *name; void *replacement; void **original; } exported[] = {
        { "HIThemeDrawTrack", sl_drawTrack, (void **)&orig_drawTrack },
        { "HIThemeGetTrackBounds", sl_trackBounds, (void **)&orig_trackBounds },
        { "HIThemeGetTrackPartBounds", sl_partBounds, (void **)&orig_partBounds },
        { "HIThemeGetTrackThumbPositionFromBounds", sl_thumbFromBounds, (void **)&orig_thumbFromBounds },
        { "HIThemeGetTrackThumbPositionFromOffset", sl_thumbFromOffset, (void **)&orig_thumbFromOffset },
        { "HIThemeGetTrackLiveValue", sl_liveValue, (void **)&orig_liveValue },
        { "HIThemeGetTrackDragRect", sl_dragRect, (void **)&orig_dragRect },
        { "HIThemeGetTrackThumbShape", sl_thumbShape, (void **)&orig_thumbShape },
        { "HIThemeHitTestTrack", sl_hitTestTrack, (void **)&orig_hitTestTrack },
        { "HIThemeHitTestScrollBarArrows", sl_hitTestArrows, (void **)&orig_hitTestArrows },
        { "HIThemeGetScrollBarTrackRect", sl_scrollBarTrackRect, (void **)&orig_scrollBarTrackRect },
    };
    void *symbols[sizeof(exported) / sizeof(exported[0])];
    for (unsigned i = 0; i < sizeof(exported) / sizeof(exported[0]); i++)
        if (!(symbols[i] = dlsym(RTLD_DEFAULT, exported[i].name))) return;

    for (unsigned i = 0; i < sizeof(exported) / sizeof(exported[0]); i++)
        hook(symbols[i], exported[i].replacement, exported[i].original);
    hook(drawSB, sl_drawScrollBar, (void **)&orig_drawScrollBar);
    hook(hitSB, sl_hitTestScrollBar, (void **)&orig_hitTestScrollBar);
    hook(dragSB, sl_scrollBarDragBounds, (void **)&orig_scrollBarDragBounds);
    hook(thumbRgn, sl_thumbRegion, (void **)&orig_thumbRegion);
    hook(useCoreUI, sl_useCoreUI, (void **)&orig_useCoreUI);

#if !__LP64__
    // AppKit's scroller style can change while the app runs: a setting
    // changed, a trackpad connected, or - with "Automatically" - AppKit
    // settling its choice shortly after launch, once it has looked at the
    // pointing devices (asynchronously), when the first windows may have been
    // drawn already. AppKit's scroll views follow it
    // (NSPreferredScrollerStyleDidChangeNotification); Carbon's windows are
    // redrawn here. (Carbon windows exist only in 32-bit processes.) The
    // observer is kept: under GC the notification center holds it weakly.
    static id observer;
    observer = [[[NSNotificationCenter defaultCenter] addObserverForName:NSPreferredScrollerStyleDidChangeNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (WindowRef window = GetWindowList(); window; window = GetNextWindow(window))
            SLCarbonRedraw(HIViewGetRoot(window));
#pragma clang diagnostic pop
    }] retain];
#endif
}
