//
//  SLWebKit.m
//  Snow Leopard scroll bars inside WebKit content (Safari pages, WebViews).
//
//  WebKit does not use NSScroller for page scrollbars. Its ScrollbarThemeMac
//  configures an NSScrollerImp (enabled, size, value, proportion) and calls
//  -drawKnobSlotInRect:highlight: and -drawKnob on it; WebCore does its own
//  layout and hit testing.
//
//  WebKit changes between versions and Mavericks has third-party backports,
//  so this file never uses WebCore struct offsets or hard-coded addresses.
//  Like the AppKit side, it only acts while scrollbars use the legacy style;
//  with overlay scrollbars ("show scroll bars when scrolling") every override
//  defers to WebKit's own code.
//  It works in independent layers; each one finds what it needs by name,
//  checks it, and switches itself off (leaving that part of WebKit alone) if
//  anything is missing:
//
//   1. Appearance  NSScrollerImp drawing hooks, AppKit API only. Applied to
//                  scroller imps that no NSScroller owns (i.e. WebKit's).
//   2. Arrows      Re-enables WebCore's (still present) scroll arrow layout
//                  and gives it 10.6 geometry, by replacing six
//                  ScrollbarThemeMac virtual methods. Each method is looked
//                  up by its exact mangled name and must appear exactly once
//                  in ScrollbarThemeMac's vtable, or nothing is patched.
//                  Without this layer scrollbars are drawn without arrows,
//                  with the knob where WebCore expects it.
//   3. Pressed     Highlights a pressed arrow while the mouse is on it. Hooks
//                  Scrollbar::setPressedPart / setHoveredPart (WebCore's own
//                  hit-test results) with MIP's MSHookFunction.
//   4. Inactive    Draws the inactive (clear) look in background windows.
//                  Uses the window being drawn into when there is one
//                  (in-process WebViews), otherwise the exported
//                  FocusController::setActive.
//

#import "SLScrollBars.h"
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>

@interface NSObject (SLScrollerImpPrivateAPI)
- (id)delegate;
- (id)scroller;
- (NSSize)boundsSize;
- (BOOL)isHorizontal;
- (BOOL)isEnabled;
- (NSControlSize)controlSize;
- (double)doubleValue;

- (NSInteger)scrollerStyle;
- (double)presentationValue;
- (BOOL)shouldUsePresentationValue;
- (BOOL)_hasActiveControls;
@end

// ---- WebCore types (stable since 2008) ---------------------------------------

typedef struct { int x, y, width, height; } SLIntRect;   // WebCore::IntRect

enum {  // WebCore::ScrollbarPart
    kWKBackButtonStartPart    = 1 << 0,
    kWKForwardButtonStartPart = 1 << 1,
    kWKBackButtonEndPart      = 1 << 5,
    kWKForwardButtonEndPart   = 1 << 6,
};
// WebCore::ScrollbarButtonsPlacement uses the same numbering as kSLArrows*:
// None 0, Single 1, DoubleStart 2, DoubleEnd 3, DoubleBoth 4.

// ---- symbol lookup ------------------------------------------------------------

#if __LP64__
typedef struct mach_header_64 SLMachHeader;
typedef struct segment_command_64 SLSegmentCommand;
typedef struct nlist_64 SLNlist;
#define SL_MH_MAGIC MH_MAGIC_64
#define SL_LC_SEGMENT LC_SEGMENT_64
#else
typedef struct mach_header SLMachHeader;
typedef struct segment_command SLSegmentCommand;
typedef struct nlist SLNlist;
#define SL_MH_MAGIC MH_MAGIC
#define SL_LC_SEGMENT LC_SEGMENT
#endif

// Looks a symbol up in a loaded image's own symbol table, including local
// (non-exported) symbols, which WebKit's builds keep. Images in the dyld
// shared cache have no local symbols in memory; this then fails cleanly.
static void *SLFindSymbolInImage(const SLMachHeader *header, intptr_t slide, const char *name)
{
    if (header->magic != SL_MH_MAGIC) return NULL;
    const SLSegmentCommand *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct load_command *cmd = (const struct load_command *)(header + 1);
    for (unsigned i = 0; i < header->ncmds; i++, cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd == SL_LC_SEGMENT && strcmp(((const SLSegmentCommand *)cmd)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const SLSegmentCommand *)cmd;
        else if (cmd->cmd == LC_SYMTAB)
            symtab = (const struct symtab_command *)cmd;
    }
    if (!linkedit || !symtab) return NULL;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const SLNlist *symbols = (const SLNlist *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if ((symbols[i].n_type & N_STAB) || (symbols[i].n_type & N_TYPE) != N_SECT) continue;
        uint32_t strx = symbols[i].n_un.n_strx;
        if (strx && strcmp(strings + strx, name) == 0) return (void *)(symbols[i].n_value + slide);
    }
    return NULL;
}

// ---- state shared by the layers -------------------------------------------

static BOOL gArrowsLayer = NO;          // layer 2 active
static BOOL SLLayerDisabled(NSString *name);
static void *gPressedScrollbar = NULL;  // layer 3: the WebCore::Scrollbar being pressed
static int gPressedPart = 0;            //          WebCore::ScrollbarPart pressed
static int gHoveredPart = 0;            //          and the part the mouse is now over
static BOOL gHaveFocusState = NO;       // layer 4
static BOOL gFocusActive = YES;
static NSHashTable *gWebScrollerImps = nil;                         // imps drawn so far (weak)
static void (*gScrollbarInvalidateRect)(void *scrollbar, const SLIntRect *rect) = NULL;
static void *SLWebCoreScrollbarForImp(id imp);

// Newer WebKit can have scrollbars drawn on its scrolling thread, so the set
// of imps is guarded.
static void SLNoteWebScrollerImp(id imp)
{
    @synchronized (gWebScrollerImps) { [gWebScrollerImps addObject:imp]; }
}

static NSArray *SLWebScrollerImps(void)
{
    @synchronized (gWebScrollerImps) { return [[[gWebScrollerImps allObjects] retain] autorelease]; }
}

// ---- layer 2: arrows ---------------------------------------------------------

typedef SLIntRect (*SLTrackRectFn)(void *theme, void *scrollbar, bool painting);
typedef bool (*SLScrollbarPredicateFn)(void *theme, void *scrollbar);
typedef SLIntRect (*SLButtonRectFn)(void *theme, void *scrollbar, int part, bool painting);

static int (*orig_buttonsPlacement)(void *theme);
static SLTrackRectFn orig_trackRect;
static SLScrollbarPredicateFn orig_hasButtons;
static SLScrollbarPredicateFn orig_hasThumb;
static SLButtonRectFn orig_backButtonRect;
static SLButtonRectFn orig_forwardButtonRect;

// WebKit takes its scrollbar style from AppKit's recommendation, as NSScroll-
// View does: overlay scrollbars ("when scrolling") are left entirely alone.
static BOOL SLWebKitUsesLegacyScrollbars(void)
{
    return SLIsEnabled() && [NSScroller preferredScrollerStyle] == NSScrollerStyleLegacy;
}

// Geometry from the scrollbar's frame alone: WebCore's trackRect(painting:
// true) has always returned Widget::frameRect().
static SLState SLStateForWebCoreScrollbar(void *theme, void *scrollbar, SLIntRect *frame)
{
    *frame = orig_trackRect(theme, scrollbar, true);
    SLState st;
    memset(&st, 0, sizeof(st));
    st.bounds = NSMakeRect(0, 0, frame->width, frame->height);
    st.horizontal = frame->width >= frame->height;
    CGFloat thickness = st.horizontal ? frame->height : frame->width;
    st.small = thickness < 13;
    st.thickness = st.small ? 11 : 15;
    st.enabled = YES;
    st.flipped = YES;
    st.config = SLArrowConfig();
    st.webKitMetrics = YES;
    st.pressedArrow = -1;
    return st;
}

static inline SLIntRect SLOffsetRect(NSRect r, const SLIntRect *frame)
{
    if (NSIsEmptyRect(r)) return (SLIntRect){ 0, 0, 0, 0 };
    return (SLIntRect){ frame->x + (int)r.origin.x, frame->y + (int)r.origin.y, (int)r.size.width, (int)r.size.height };
}

static int sl_wk_buttonsPlacement(void *theme)
{
    if (!SLWebKitUsesLegacyScrollbars()) return orig_buttonsPlacement(theme);
    return SLArrowConfig();
}

static bool sl_wk_hasButtons(void *theme, void *scrollbar)
{
    if (!SLWebKitUsesLegacyScrollbars()) return orig_hasButtons(theme, scrollbar);
    if (!orig_hasButtons(theme, scrollbar)) return false;   // also checks the scrollbar is enabled
    SLIntRect frame;
    SLState st = SLStateForWebCoreScrollbar(theme, scrollbar, &frame);
    return SLUsableParts(&st) != NSNoScrollerParts;
}

static bool sl_wk_hasThumb(void *theme, void *scrollbar)
{
    if (!SLWebKitUsesLegacyScrollbars()) return orig_hasThumb(theme, scrollbar);
    if (!orig_hasThumb(theme, scrollbar)) return false;
    SLIntRect frame;
    SLState st = SLStateForWebCoreScrollbar(theme, scrollbar, &frame);
    return SLUsableParts(&st) == NSAllScrollerParts;
}

static SLIntRect sl_wk_trackRect(void *theme, void *scrollbar, bool painting)
{
    if (painting || !SLWebKitUsesLegacyScrollbars() || !sl_wk_hasButtons(theme, scrollbar)) return orig_trackRect(theme, scrollbar, painting);
    SLIntRect frame;
    SLState st = SLStateForWebCoreScrollbar(theme, scrollbar, &frame);
    CGFloat start, length;
    SLSlotSpan(&st, &start, &length);
    if (st.horizontal) return (SLIntRect){ frame.x + (int)start, frame.y, (int)length, frame.height };
    return (SLIntRect){ frame.x, frame.y + (int)start, frame.width, (int)length };
}

static SLIntRect SLButtonRect(void *theme, void *scrollbar, int part)
{
    if (!sl_wk_hasButtons(theme, scrollbar)) return (SLIntRect){ 0, 0, 0, 0 };
    SLIntRect frame;
    SLState st = SLStateForWebCoreScrollbar(theme, scrollbar, &frame);
    int c = st.config;
    NSScrollerPart sl = (NSScrollerPart)-1;
    switch (part) {
        case kWKBackButtonStartPart:
            if (c == kSLArrowsSingle || c == kSLArrowsDoubleMin || c == kSLArrowsDoubleBoth) sl = NSScrollerDecrementLine;
            break;
        case kWKBackButtonEndPart:
            if (c == kSLArrowsDoubleMax) sl = NSScrollerDecrementLine;
            else if (c == kSLArrowsDoubleBoth) sl = (NSScrollerPart)7;
            break;
        case kWKForwardButtonStartPart:
            if (c == kSLArrowsDoubleMin) sl = NSScrollerIncrementLine;
            else if (c == kSLArrowsDoubleBoth) sl = (NSScrollerPart)8;
            break;
        case kWKForwardButtonEndPart:
            if (c == kSLArrowsSingle || c == kSLArrowsDoubleMax || c == kSLArrowsDoubleBoth) sl = NSScrollerIncrementLine;
            break;
    }
    if (sl == (NSScrollerPart)-1) return (SLIntRect){ 0, 0, 0, 0 };
    return SLOffsetRect(SLHitRect(&st, sl), &frame);
}

static SLIntRect sl_wk_backButtonRect(void *theme, void *scrollbar, int part, bool painting)
{
    if (!SLWebKitUsesLegacyScrollbars()) return orig_backButtonRect(theme, scrollbar, part, painting);
    return SLButtonRect(theme, scrollbar, part);
}

static SLIntRect sl_wk_forwardButtonRect(void *theme, void *scrollbar, int part, bool painting)
{
    if (!SLWebKitUsesLegacyScrollbars()) return orig_forwardButtonRect(theme, scrollbar, part, painting);
    return SLButtonRect(theme, scrollbar, part);
}

/* The scrollbar parameter of these methods has been spelled three ways over
   WebKit's history; all of them are one pointer at the machine level, and the
   replacements only hand it back to WebKit, so any of them works. All six
   methods must come from the same spelling. */
static const char *kScrollbarParameterSpellings[] = {
    "RNS_9ScrollbarE",                  // Scrollbar&             (2015 on)
    "PNS_20ScrollbarThemeClientE",      // ScrollbarThemeClient*  (about 2012-2015)
    "PNS_9ScrollbarE",                  // Scrollbar*             (before)
};

static void SLInstallArrowsLayer(const SLMachHeader *header, intptr_t slide)
{
    struct { const char *format; void *replacement; void **original; void *address; long slot; char name[160]; } methods[] = {
        { "__ZNK7WebCore17ScrollbarThemeMac16buttonsPlacementEv", (void *)sl_wk_buttonsPlacement, (void **)&orig_buttonsPlacement },
        { "__ZN7WebCore17ScrollbarThemeMac10hasButtonsE%s", (void *)sl_wk_hasButtons, (void **)&orig_hasButtons },
        { "__ZN7WebCore17ScrollbarThemeMac8hasThumbE%s", (void *)sl_wk_hasThumb, (void **)&orig_hasThumb },
        { "__ZN7WebCore17ScrollbarThemeMac9trackRectE%sb", (void *)sl_wk_trackRect, (void **)&orig_trackRect },
        { "__ZN7WebCore17ScrollbarThemeMac14backButtonRectE%sNS_13ScrollbarPartEb", (void *)sl_wk_backButtonRect, (void **)&orig_backButtonRect },
        { "__ZN7WebCore17ScrollbarThemeMac17forwardButtonRectE%sNS_13ScrollbarPartEb", (void *)sl_wk_forwardButtonRect, (void **)&orig_forwardButtonRect },
    };
    const unsigned count = sizeof(methods) / sizeof(methods[0]);

    const char *spelling = NULL;
    for (unsigned k = 0; k < sizeof(kScrollbarParameterSpellings) / sizeof(kScrollbarParameterSpellings[0]) && !spelling; k++) {
        BOOL all = YES;
        for (unsigned i = 0; i < count && all; i++) {
            snprintf(methods[i].name, sizeof(methods[i].name), methods[i].format, kScrollbarParameterSpellings[k]);
            methods[i].address = SLFindSymbolInImage(header, slide, methods[i].name);
            all = methods[i].address != NULL;
        }
        if (all) spelling = kScrollbarParameterSpellings[k];
    }
    if (!spelling) {
        NSLog(@"SnowLeopardScrollBars: this WebKit's ScrollbarThemeMac has no recognisable scroll arrow methods; web scrollbars will have no arrows.");
        return;
    }
    for (unsigned i = 0; i < count; i++) methods[i].slot = -1;

    void **vtable = SLFindSymbolInImage(header, slide, "__ZTVN7WebCore17ScrollbarThemeMacE");
    if (!vtable) {
        NSLog(@"SnowLeopardScrollBars: WebCore's ScrollbarThemeMac vtable not found; web scrollbars will have no arrows.");
        return;
    }
    // Itanium layout: offset-to-top, RTTI (null with -fno-rtti), then the slots.
    void **slots = vtable + 2;

    // Each method must be in the vtable exactly once. The vtable ends at the
    // first entry that is not a pointer into WebCore's code.
    for (unsigned j = 0; j < 512; j++) {
        Dl_info info;
        if (!slots[j] || !dladdr(slots[j], &info) || info.dli_fbase != (void *)header) break;
        for (unsigned i = 0; i < count; i++) {
            if (slots[j] != methods[i].address) continue;
            if (methods[i].slot != -1) {
                NSLog(@"SnowLeopardScrollBars: %s is in ScrollbarThemeMac's vtable twice; web scrollbars will have no arrows.", methods[i].name);
                return;
            }
            methods[i].slot = j;
        }
    }
    for (unsigned i = 0; i < count; i++) {
        if (methods[i].slot == -1) {
            NSLog(@"SnowLeopardScrollBars: %s is not virtual in this WebKit; web scrollbars will have no arrows.", methods[i].name);
            return;
        }
    }

    // All verified; patch.
    for (unsigned i = 0; i < count; i++) {
        void **entry = &slots[methods[i].slot];
        vm_address_t page = (vm_address_t)entry & ~(vm_address_t)(PAGE_SIZE - 1);
        if (vm_protect(mach_task_self(), page, PAGE_SIZE, false, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS &&
            vm_protect(mach_task_self(), page, PAGE_SIZE, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
            NSLog(@"SnowLeopardScrollBars: could not write ScrollbarThemeMac's vtable; web scrollbars will have no arrows.");
            return;
        }
    }
    for (unsigned i = 0; i < count; i++) {
        if (methods[i].original) *methods[i].original = methods[i].address;
    }
    for (unsigned i = 0; i < count; i++) {
        slots[methods[i].slot] = methods[i].replacement;
    }
    gArrowsLayer = YES;
}

// ---- layers 3 and 4: exported WebCore functions ----------------------------------

typedef void (*SLHookFunctionFn)(void *symbol, void *replacement, void **original);

static void (*orig_setPressedPart)(void *scrollbar, int part);
static void (*orig_setHoveredPart)(void *scrollbar, int part);
static void (*orig_setActive)(void *focusController, bool active);
static void (*orig_setActiveInternal)(void *focusController, bool active);

static void SLRepaintWebScrollbar(void *scrollbar);

// Both run before WebCore invalidates the affected parts, so the repaint that
// follows sees the new state. WebCore only repaints the arrow's hit rectangle,
// but the pressed artwork also tints the line next to it, so repaint the whole
// scrollbar.
static void sl_wk_setPressedPart(void *scrollbar, int part)
{
    if (part) {
        gPressedScrollbar = scrollbar;
        gPressedPart = gHoveredPart = part;
    } else if (scrollbar == gPressedScrollbar) {
        gPressedScrollbar = NULL;
        gPressedPart = gHoveredPart = 0;
    }
    orig_setPressedPart(scrollbar, part);
    SLRepaintWebScrollbar(scrollbar);
}

static void sl_wk_setHoveredPart(void *scrollbar, int part)
{
    BOOL relevant = (scrollbar == gPressedScrollbar);
    if (relevant) gHoveredPart = part;
    orig_setHoveredPart(scrollbar, part);
    if (relevant) SLRepaintWebScrollbar(scrollbar);
}

/* Nothing in WebKit repaints a scrollbar when the window's activation
   changes (Lion scrollbars look the same either way), or repaints all of it
   when an arrow is pressed. Depending on the WebKit build, a page scrollbar is
   drawn in one of two ways, so ask for both:
    - WebCore paints it into its own layer on the main thread: ask WebCore to
      repaint the scrollbar.
    - AppKit draws the imp into layers of its own (newer WebKit, where the
      scrolling thread updates scrollbars): redraw those layers. */
static void SLRepaintImp(id imp, void *scrollbar)
{
    if (scrollbar && gScrollbarInvalidateRect) {
        NSSize size = [imp boundsSize];
        SLIntRect rect = { 0, 0, (int)size.width, (int)size.height };
        gScrollbarInvalidateRect(scrollbar, &rect);
    }
    SEL layers[] = { @selector(layer), @selector(trackLayer), @selector(knobLayer) };
    for (unsigned i = 0; i < sizeof(layers) / sizeof(layers[0]); i++) {
        if ([imp respondsToSelector:layers[i]]) [((CALayer *(*)(id, SEL))objc_msgSend)(imp, layers[i]) setNeedsDisplay];
    }
}

static void SLRepaintWebScrollbar(void *scrollbar)
{
    if (!scrollbar || !SLWebKitUsesLegacyScrollbars()) return;
    for (id imp in SLWebScrollerImps()) {
        if (SLWebCoreScrollbarForImp(imp) == scrollbar) SLRepaintImp(imp, scrollbar);
    }
}

static void SLRepaintWebScrollbars(void)
{
    for (id imp in SLWebScrollerImps()) SLRepaintImp(imp, SLWebCoreScrollbarForImp(imp));
}

// Records the new state before WebCore acts on it; returns whether it changed.
static BOOL SLFocusStateChanged(bool active)
{
    BOOL changed = !gHaveFocusState || gFocusActive != active;
    gHaveFocusState = YES;
    gFocusActive = active;
    return changed;
}

static void sl_wk_setActive(void *focusController, bool active)
{
    BOOL changed = SLFocusStateChanged(active);
    orig_setActive(focusController, active);
    if (changed) SLRepaintWebScrollbars();
}

// Newer WebKit (2015 on) routes window activation through
// FocusController::setViewState / setActivityState into this one instead.
static void sl_wk_setActiveInternal(void *focusController, bool active)
{
    BOOL changed = SLFocusStateChanged(active);
    orig_setActiveInternal(focusController, active);
    if (changed) SLRepaintWebScrollbars();
}

/* A press on a scroll arrow can reach WebCore late: in a window's resize
   corner, AppKit holds it back until it has been held still for a while (see
   SLScrollBars.m). The time it was held counts toward the arrow's wait before
   it starts repeating (ScrollbarThemeMac::initialAutoscrollTimerDelay, which
   Scrollbar::mouseDown asks for), as it does for NSScroller. The press's time
   is the event's timestamp, which WebCore's PlatformMouseEvent keeps among
   its first fields, as a double: seconds since boot in older WebKit, since
   1970 (WallTime) in newer. It is found as the first value there that is a
   time in the last minute on either clock; with none, nothing changes. */
static bool (*orig_scrollbarMouseDown)(void *scrollbar, const void *event);
static double (*orig_initialAutoscrollDelay)(void *theme);
static double gWKPressHeld = -1;            // how long the press being handled had been held, or -1

static bool sl_wk_scrollbarMouseDown(void *scrollbar, const void *event)
{
    double uptime = [[NSProcessInfo processInfo] systemUptime];
    double wall = [[NSDate date] timeIntervalSince1970];
    const double *fields = (const double *)event;
    gWKPressHeld = -1;
    for (int i = 0; i < 8 && gWKPressHeld < 0; i++) {
        double t = fields[i];
        if (t > uptime - 60 && t <= uptime + 1) gWKPressHeld = MAX(0, uptime - t);
        else if (t > wall - 60 && t <= wall + 1) gWKPressHeld = MAX(0, wall - t);
    }
    bool result = orig_scrollbarMouseDown(scrollbar, event);
    gWKPressHeld = -1;
    return result;
}

static double sl_wk_initialAutoscrollDelay(void *theme)
{
    double delay = orig_initialAutoscrollDelay(theme);
    if (gWKPressHeld > 0) delay = MAX(0, delay - gWKPressHeld);
    return delay;
}

static void SLInstallEventLayers(const SLMachHeader *header, intptr_t slide, const char *path)
{
    SLHookFunctionFn hook = (SLHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!hook) {
        NSLog(@"SnowLeopardScrollBars: MSHookFunction unavailable (not loaded by MIP?); web scroll arrows will not highlight.");
        return;
    }
    void *webcore = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
    if (!webcore) return;

    void *setPressed = SLFindSymbolInImage(header, slide, "__ZN7WebCore9Scrollbar14setPressedPartENS_13ScrollbarPartE");
    void *setHovered = SLFindSymbolInImage(header, slide, "__ZN7WebCore9Scrollbar14setHoveredPartENS_13ScrollbarPartE");
    if (setPressed && setHovered && !SLLayerDisabled(@"pressed")) {
        hook(setPressed, (void *)sl_wk_setPressedPart, (void **)&orig_setPressedPart);
        hook(setHovered, (void *)sl_wk_setHoveredPart, (void **)&orig_setHoveredPart);
    } else if (!setPressed || !setHovered) {
        NSLog(@"SnowLeopardScrollBars: WebCore::Scrollbar::setPressedPart/setHoveredPart not found; web scroll arrows will not highlight.");
    }

    // Window activation. Older WebKit does the work in the exported
    // setActive(bool); newer WebKit in setActiveInternal(bool), which is not
    // exported. Hook whichever exist; with both, the wrapper calls the
    // internal one and the state is just recorded twice.
    void *setActive = dlsym(webcore, "_ZN7WebCore15FocusController9setActiveEb");
    void *setActiveInternal = SLFindSymbolInImage(header, slide, "__ZN7WebCore15FocusController17setActiveInternalEb");
    if (SLLayerDisabled(@"active")) setActive = setActiveInternal = NULL;
    if (setActive) hook(setActive, (void *)sl_wk_setActive, (void **)&orig_setActive);
    if (setActiveInternal) hook(setActiveInternal, (void *)sl_wk_setActiveInternal, (void **)&orig_setActiveInternal);
    void *mouseDown = SLFindSymbolInImage(header, slide, "__ZN7WebCore9Scrollbar9mouseDownERKNS_18PlatformMouseEventE");
    void *initialDelay = SLFindSymbolInImage(header, slide, "__ZN7WebCore17ScrollbarThemeMac27initialAutoscrollTimerDelayEv");
    if (mouseDown && initialDelay && !SLLayerDisabled(@"repeat")) {
        hook(mouseDown, (void *)sl_wk_scrollbarMouseDown, (void **)&orig_scrollbarMouseDown);
        hook(initialDelay, (void *)sl_wk_initialAutoscrollDelay, (void **)&orig_initialAutoscrollDelay);
    }
    gScrollbarInvalidateRect = SLFindSymbolInImage(header, slide, "__ZN7WebCore9Scrollbar14invalidateRectERKNS_7IntRectE");
    if (!gScrollbarInvalidateRect) {
        NSLog(@"SnowLeopardScrollBars: WebCore::Scrollbar::invalidateRect not found; web scrollbars WebCore paints may update late.");
    }
    if (!setActive && !setActiveInternal) {
        NSLog(@"SnowLeopardScrollBars: WebCore::FocusController activation not found; web scrollbars will always look active.");
    }
    dlclose(webcore);
}

// ---- layer 1: NSScrollerImp drawing -----------------------------------------------

// Scroller imps owned by an NSScroller are drawn by SLScrollBars.m; this is
// for the rest, which in practice means WebKit's.
static BOOL SLIsWebScrollerImp(id imp)
{
    if (!SLIsEnabled()) return NO;
    if ([imp respondsToSelector:@selector(scrollerStyle)] && [imp scrollerStyle] != NSScrollerStyleLegacy) return NO;
    id scroller = [imp respondsToSelector:@selector(scroller)] ? [imp scroller] : nil;
    if (scroller) return NO;
    id delegate = [imp respondsToSelector:@selector(delegate)] ? [imp delegate] : nil;
    return delegate && ![delegate isKindOfClass:[NSScroller class]];
}

/* Which WebCore::Scrollbar an imp belongs to. WebKit's imp delegate is made
   with -initWithScrollbar:(WebCore::Scrollbar *) and sent -invalidate when the
   scrollbar goes away; the pointer is recorded in between. (How the delegate
   stores it varies: a plain pointer in older WebKit, a WeakPtr in newer.) */
static char kSLScrollbarKey;

static void SLHookScrollbarDelegates(const char *imagePath)
{
    SEL initSel = @selector(initWithScrollbar:);
    SEL invalidateSel = @selector(invalidate);
    unsigned count = 0;
    const char **names = objc_copyClassNamesForImage(imagePath, &count);
    for (unsigned i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        Method init = NULL, invalidate = NULL;
        unsigned n = 0;
        Method *methods = class_copyMethodList(cls, &n);
        for (unsigned j = 0; j < n; j++) {
            if (method_getName(methods[j]) == initSel) init = methods[j];
            else if (method_getName(methods[j]) == invalidateSel) invalidate = methods[j];
        }
        free(methods);
        // One pointer argument: self, _cmd, scrollbar.
        char *argType = init ? method_copyArgumentType(init, 2) : NULL;
        BOOL pointerArg = argType && argType[0] == '^';
        free(argType);
        if (!pointerArg || !invalidate || method_getNumberOfArguments(init) != 3) continue;

        id (*origInit)(id, SEL, void *) = (void *)method_getImplementation(init);
        method_setImplementation(init, imp_implementationWithBlock(^id(id delegate, void *scrollbar) {
            delegate = origInit(delegate, initSel, scrollbar);
            if (delegate && scrollbar) objc_setAssociatedObject(delegate, &kSLScrollbarKey, [NSValue valueWithPointer:scrollbar], OBJC_ASSOCIATION_RETAIN);
            return delegate;
        }));
        void (*origInvalidate)(id, SEL) = (void *)method_getImplementation(invalidate);
        method_setImplementation(invalidate, imp_implementationWithBlock(^(id delegate) {
            objc_setAssociatedObject(delegate, &kSLScrollbarKey, nil, OBJC_ASSOCIATION_RETAIN);
            origInvalidate(delegate, invalidateSel);
        }));
    }
    free(names);
}

static void *SLWebCoreScrollbarForImp(id imp)
{
    id delegate = [imp delegate];
    NSValue *recorded = objc_getAssociatedObject(delegate, &kSLScrollbarKey);
    if (recorded) return [recorded pointerValue];

    // Delegates made before the hook: read a plain-pointer ivar.
    Ivar ivar = class_getInstanceVariable([delegate class], "_scrollbar");
    // Only a pointer to WebCore::Scrollbar itself (not, say, one of its base
    // classes, which would sit at a different address) is usable.
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || (strncmp(type, "^{Scrollbar=", 12) != 0 && strcmp(type, "^{Scrollbar}") != 0)) {
        static BOOL logged = NO;
        if (!logged && delegate) {
            logged = YES;
            NSLog(@"SnowLeopardScrollBars: can't find the WebCore::Scrollbar of %@ (_scrollbar: %s); pressed web scroll arrows will not light up.",
                  NSStringFromClass([delegate class]), ivar ? (type ? type : "untyped") : "missing");
        }
        return NULL;
    }
    return *(void **)((char *)delegate + ivar_getOffset(ivar));
}

static BOOL SLWebContentIsActive(void)
{
    // In-process WebViews draw into their window's view hierarchy.
    NSWindow *window = [[NSView focusView] window];
    if (window) {
        return [window respondsToSelector:@selector(_hasActiveControls)] ? [window _hasActiveControls] : [window isKeyWindow];
    }
    // Out of process (Safari's WebContent): the page's activation state.
    return gHaveFocusState ? gFocusActive : YES;
}

static BOOL SLWebContentIsActive(void);
static SLState SLStateForImp(id imp)
{
    SLState st;
    memset(&st, 0, sizeof(st));
    NSSize size = [imp boundsSize];
    st.bounds = NSMakeRect(0, 0, size.width, size.height);
    st.horizontal = [imp isHorizontal];
    st.small = ([imp controlSize] != NSRegularControlSize);
    st.thickness = st.small ? 11 : 15;
    st.enabled = [imp isEnabled];
    st.flipped = [[NSGraphicsContext currentContext] isFlipped];
    BOOL presentation = [imp respondsToSelector:@selector(shouldUsePresentationValue)] && [imp shouldUsePresentationValue];
    st.value = presentation ? [imp presentationValue] : [imp doubleValue];
    st.proportion = ((double (*)(id, SEL))objc_msgSend)(imp, @selector(knobProportion));
    st.webKitMetrics = YES;
    st.config = gArrowsLayer ? SLArrowConfig() : 0;
    st.fullLengthSlot = !gArrowsLayer;
    st.active = SLWebContentIsActive();
    st.arrowsActive = st.active;
    st.tint = st.active ? [NSColor currentControlTint] : NSClearControlTint;
    st.pressedArrow = -1;

    // Layer 3: like AppKit, the pressed arrow is lit while the mouse is on it.
    if (gPressedScrollbar && gArrowsLayer && gHoveredPart == gPressedPart && SLWebCoreScrollbarForImp(imp) == gPressedScrollbar) {
        switch (gPressedPart) {
            case kWKBackButtonStartPart:    st.pressedArrow = NSScrollerDecrementArrow; st.pressedInMaxEnd = NO;  break;
            case kWKForwardButtonStartPart: st.pressedArrow = NSScrollerIncrementArrow; st.pressedInMaxEnd = NO;  break;
            case kWKBackButtonEndPart:      st.pressedArrow = NSScrollerDecrementArrow; st.pressedInMaxEnd = YES; break;
            case kWKForwardButtonEndPart:   st.pressedArrow = NSScrollerIncrementArrow; st.pressedInMaxEnd = YES; break;
        }
    }
    return st;
}

static void (*orig_drawKnobSlot)(id, SEL, NSRect, BOOL);
static void (*orig_drawKnob)(id, SEL);
static double (*orig_regularKnobMinLength)(id, SEL);
static double (*orig_smallKnobMinLength)(id, SEL);

static void sl_imp_drawKnobSlot(id self, SEL _cmd, NSRect rect, BOOL highlight)
{
    if (!SLIsWebScrollerImp(self)) { orig_drawKnobSlot(self, _cmd, rect, highlight); return; }
    SLNoteWebScrollerImp(self);
    SLState st = SLStateForImp(self);
    SLPaintSlot(&st, SLDrawingRect(&st, NSScrollerKnobSlot));
    if (st.enabled) {
        SLPaintArrow(&st, NSScrollerDecrementArrow, SLHighlightPartForEnd(&st, YES));
        SLPaintArrow(&st, NSScrollerIncrementArrow, SLHighlightPartForEnd(&st, NO));
    }
}

static void sl_imp_drawKnob(id self, SEL _cmd)
{
    if (!SLIsWebScrollerImp(self)) { orig_drawKnob(self, _cmd); return; }
    SLNoteWebScrollerImp(self);
    SLState st = SLStateForImp(self);
    SLPaintKnob(&st);
}

// WebCore's minimumThumbLength() asks the imp.
static double sl_imp_regularKnobMinLength(id self, SEL _cmd)
{
    if (!SLIsWebScrollerImp(self)) return orig_regularKnobMinLength(self, _cmd);
    return SLMinimumKnobLength(NO);
}

static double sl_imp_smallKnobMinLength(id self, SEL _cmd)
{
    if (!SLIsWebScrollerImp(self)) return orig_smallKnobMinLength(self, _cmd);
    return SLMinimumKnobLength(YES);
}

static void SLInstallImpLayer(void)
{
    Class imp = NSClassFromString(@"NSScrollerImp");
    if (!imp) return;
    SLHook(imp, @selector(drawKnobSlotInRect:highlight:), (IMP)sl_imp_drawKnobSlot, (IMP *)&orig_drawKnobSlot);
    SLHook(imp, @selector(drawKnob), (IMP)sl_imp_drawKnob, (IMP *)&orig_drawKnob);

    SEL classForStyle = NSSelectorFromString(@"scrollerImpClassForStyle:controlSize:");
    if ([imp respondsToSelector:classForStyle]) {
        Class (*classFor)(id, SEL, NSScrollerStyle, NSControlSize) = (void *)objc_msgSend;
        Class regular = classFor(imp, classForStyle, NSScrollerStyleLegacy, NSRegularControlSize);
        Class small = classFor(imp, classForStyle, NSScrollerStyleLegacy, NSSmallControlSize);
        if (regular) SLHook(regular, @selector(knobMinLength), (IMP)sl_imp_regularKnobMinLength, (IMP *)&orig_regularKnobMinLength);
        if (small && small != regular) SLHook(small, @selector(knobMinLength), (IMP)sl_imp_smallKnobMinLength, (IMP *)&orig_smallKnobMinLength);
    }
}

// ---- setup ---------------------------------------------------------------------

static BOOL SLIsWebCorePath(const char *path)
{
    const char *suffix = "/WebCore.framework/Versions/A/WebCore";
    size_t n = strlen(path), m = strlen(suffix);
    return n >= m && strcmp(path + n - m, suffix) == 0;
}

/* `defaults write -g SLDisabledWebKitLayers -array arrows` (or appearance,
   pressed, active) switches individual layers off, e.g. if a WebKit build
   misbehaves with one of them. */
static BOOL SLLayerDisabled(NSString *name)
{
    NSArray *disabled = [[NSUserDefaults standardUserDefaults] arrayForKey:@"SLDisabledWebKitLayers"];
    return [disabled isKindOfClass:[NSArray class]] && [disabled containsObject:name];
}

static void SLAttachToWebCore(const struct mach_header *header, intptr_t slide, const char *path)
{
    static const struct mach_header *attached = NULL;
    if (attached) return;   // one WebCore per process
    attached = header;
    if (!SLLayerDisabled(@"arrows")) SLInstallArrowsLayer((const SLMachHeader *)header, slide);
    SLInstallEventLayers((const SLMachHeader *)header, slide, path);
    if (!SLLayerDisabled(@"pressed")) SLHookScrollbarDelegates(path);
}

static void SLImageAdded(const struct mach_header *header, intptr_t slide)
{
    // Called with dyld's lock held: no dlopen/dlsym here; finish on the main queue.
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname || !SLIsWebCorePath(info.dli_fname)) return;
    char *path = strdup(info.dli_fname);
    dispatch_async(dispatch_get_main_queue(), ^{
        SLAttachToWebCore(header, slide, path);
        free(path);
    });
}

void SLWebKitInstall(void)
{
    if (SLLayerDisabled(@"appearance")) return;   // everything else builds on it
    gWebScrollerImps = [[NSHashTable weakObjectsHashTable] retain];
    SLInstallImpLayer();

    // WebCore is usually loaded already (WebContent links it); attach now so
    // the first page is laid out with arrows. Apps that load WebKit later are
    // caught by the image callback.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && SLIsWebCorePath(path)) {
            SLAttachToWebCore(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), path);
        }
    }
    _dyld_register_func_for_add_image(SLImageAdded);
}
