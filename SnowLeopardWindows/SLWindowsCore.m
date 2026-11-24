//
//  SLWindowsCore.m
//  Snow Leopard window title bars and title bar buttons for Mavericks (MIP
//  plugin): the plugin's main executable.
//
//  AppKit draws window chrome through CoreUI's CUIDraw(), naming the part in
//  the options dictionary:
//
//    titlebarclose, titlebarcollapse,   the title bar buttons; "state" (normal,
//    titlebarzoom, titlebartoolbar      rollover, pressed, disabled),
//                                       kCUIPresentationStateKey (ActiveKey,
//                                       ActiveMain, Inactive), "value" (1 when
//                                       the document has unsaved changes),
//                                       "windowtype" (regularwin, utilwin.*)
//    kCUIWidgetWindowFrame              the title bar / unified toolbar
//                                       background
//
//  Snow Leopard's CoreUI took the same options. This plugin hooks CUIDraw and
//  draws those parts as 10.6 did; everything else goes to CoreUI unchanged.
//
//  Buttons: 10.6's own images, extracted by extract.sh from Snow Leopard's
//  ArtFile.bin (see extract_art.py), drawn exactly as stored, at 10.6's
//  positions: in standard windows 10.6 spaced them 7 points apart (Mavericks 6),
//  8 points from the left edge (Mavericks 7) and a point lower. Utility panels
//  are laid out the same in both.
//
//  Title: 10.6 drew it in black (black at 63% opacity in an inactive window),
//  with a white shadow one point below and without LCD font smoothing.
//
//  Title bar: 10.6 fills it with CUIRenderer::CreateGrayCubicGradientImage,
//      v(t) = s + D(t^3 - 1.5t^2 - 0.5t),  D = s - e,
//  from gray 197 to 150 (active) or 233 to 207 (inactive), as an 8-bit gray
//  image that the system colour-matches to the display like any other art.
//  Row 0 is a highlight (40% white over the gradient) and, when CoreUI is asked
//  for a title separator, the last row is the separator line (gray 63, or 135
//  when inactive). These values (from 10.6's CoreUI code and colour table)
//  reproduce 10.6 screenshots of active title bars and unified toolbars of any
//  height, and of inactive ones.
//
//  Bottom bar (kCUIWidgetWindowBottomBar): the same, from 191 to 150 (229 to 207
//  inactive) below a separator. Toolbar baseline (kCUIWidgetToolbarBaselineSeparator):
//  the separator line.
//
//  Textured windows (kCUIWindowTypeTextured; the frame request covers the whole
//  window): flat gray 150 (207 inactive), the title bar gradient over the top
//  area, and at the bottom either the bottom bar gradient or, without a bottom
//  bar, 10 rows from 150 to 125 (207 to 182 inactive). They use the standard
//  title bar buttons, as in 10.6. Without a toolbar the top area is the title
//  bar plus 2 points (Mavericks extends it by 75), and the window's background
//  pattern, which some views paint behind themselves, is drawn the same way.
//
//  Apps with their own look: an app can give a window its own NSAppearance,
//  built from a CoreUI catalog of its own (Reminders' leather, for one); CoreUI
//  then draws that window's chrome with the appearance's renderer. Those
//  renderers are passed through untouched, and such windows also keep
//  Mavericks' button positions, title and textured background: only the
//  standard (default) appearance gets Snow Leopard's.
//

//  The plugin is one bundle with two executables. This one, the bundle's main
//  executable, uses no AppKit, so it can go into any app with HIToolbox -
//  Cocoa and Carbon apps alike, Carbon ones without AppKit included: it
//  hooks CUIDraw (which AppKit and HIToolbox both draw window chrome with)
//  and Carbon's title bar button layout. SnowLeopardWindows-AppKit (SLWindows.m),
//  the AppKit-specific rest - AppKit's button layout and title text, textured
//  windows' background pattern, apps' own button and tab images - it loads
//  only into apps that have AppKit, when they do (some load it later).
//

#import "SLWindowsShared.h"
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <libkern/OSAtomic.h>

static SLCUIDrawFn orig_CUIDraw;

// ---- windows with their own appearance ---------------------------------------------------

// The CoreUI renderers of non-default NSAppearances (an app's own theme), as
// the AppKit part sees them handed out (SLWindows.m); CUIDraw passes their
// drawing through unchanged.
static CFMutableSetRef gCustomRenderers;
static OSSpinLock gCustomRenderersLock = OS_SPINLOCK_INIT;

static void SLRegisterCustomRenderer(void *renderer)
{
    OSSpinLockLock(&gCustomRenderersLock);
    if (!gCustomRenderers) gCustomRenderers = CFSetCreateMutable(NULL, 0, NULL);
    CFSetAddValue(gCustomRenderers, renderer);
    OSSpinLockUnlock(&gCustomRenderersLock);
}

static BOOL SLIsCustomRenderer(CFTypeRef renderer)
{
    if (!renderer) return NO;
    OSSpinLockLock(&gCustomRenderersLock);
    BOOL custom = gCustomRenderers && CFSetContainsValue(gCustomRenderers, renderer);
    OSSpinLockUnlock(&gCustomRenderersLock);
    return custom;
}

// ---- CUIDraw ----------------------------------------------------------------------------

static BOOL SLIsSnowLeopardWindowType(NSString *windowType)
{
    return !windowType || [windowType isEqualToString:@"regularwin"] || [windowType hasPrefix:@"utilwin"]
        || [windowType isEqualToString:@"kCUIWindowTypeTextured"];
}

static OSStatus sl_CUIDraw(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result)
{
    NSDictionary *o = (NSDictionary *)options;
    NSString *widget = [o isKindOfClass:[NSDictionary class]] ? o[@"widget"] : nil;
    if (!ctx || ![widget isKindOfClass:[NSString class]] || [o[@"kCUIMaskOnlyKey"] boolValue] || !SLIsSnowLeopardWindowType(o[@"windowtype"])
        || SLIsCustomRenderer(renderer))
        return orig_CUIDraw(renderer, rect, ctx, options, result);

    if ([widget hasPrefix:@"titlebar"]) {
        NSString *name = SLButtonImageName(o);
        if (name) {
            BOOL flipped = [o[@"is.flipped"] boolValue];
            // A Carbon window (HIToolbox, which aligns the art in the
            // rectangle: kCUIHorizontalAlignmentKey) asks for a button offset
            // from its view, and clips to the view: a standard window's a
            // point left of and above it, a utility window's a point right of
            // and two below it. 10.6's button fills the view (where AppKit's
            // utility windows put theirs, too).
            if (o[@"kCUIHorizontalAlignmentKey"]) {
                NSString *type = o[@"windowtype"];
                if ([type isEqualToString:@"regularwin"]) rect = CGRectOffset(rect, 1, flipped ? 1 : -1);
                else if ([type hasPrefix:@"utilwin"]) rect = CGRectOffset(rect, -1, flipped ? -2 : 2);
            }
            SLDrawButton(name, rect, ctx, flipped);
            return noErr;
        }
    } else if ([widget isEqualToString:@"kCUIWidgetWindowFrame"]) {
        OSStatus status = orig_CUIDraw(renderer, rect, ctx, options, result);
        if ([o[@"windowtype"] isEqualToString:@"kCUIWindowTypeTextured"]) SLDrawTexturedFrame(rect, ctx, o);
        else SLDrawRegularFrame(rect, ctx, o);
        return status;
    } else if ([widget isEqualToString:@"kCUIWidgetWindowBottomBar"] && o[@"windowtype"]) {
        OSStatus status = orig_CUIDraw(renderer, rect, ctx, options, result);
        SLDrawBottomBar(rect, ctx, o);
        return status;
    } else if ([widget isEqualToString:@"kCUIWidgetToolbarBaselineSeparator"] && o[@"windowtype"]) {
        SLDrawToolbarSeparator(rect, ctx, o);
        return noErr;
    }
    return orig_CUIDraw(renderer, rect, ctx, options, result);
}

// ---- Carbon windows' buttons ---------------------------------------------------------------
//
// A Carbon window (HIToolbox) lays out its own title bar buttons
// (HIWindowFrameView::GetWidgetFrame), at Mavericks' positions: 7, 27 and 47
// points from the left. In standard windows 10.6 put them at 8, 29 and 50, as
// AppKit's (SLHookLayout); utility windows' are the same in both. Each button
// is placed after the one before it (its current frame), so each moves a
// point further than that one. (Carbon windows exist only in 32-bit processes.)

#if !__LP64__
typedef void *(*SLFindSymbolFn)(const void *image, const char *name);
typedef const void *(*SLGetImageFn)(const char *name);

static uintptr_t (*orig_getWidgetFrame)(void *, void *, unsigned, CGRect *);
static WindowRef (*SLHIViewGetWindowRef)(void *);       // HIView::GetWindowRef()

static uintptr_t sl_getWidgetFrame(void *self, void *unused, unsigned part, CGRect *frame)
{
    uintptr_t result = orig_getWidgetFrame(self, unused, part, frame);
    if (!frame || (part != 'clos' && part != 'coll' && part != 'zoom')) return result;
    WindowRef window = SLHIViewGetWindowRef(self);
    WindowClass windowClass;
    if (!window || GetWindowClass(window, &windowClass) != noErr
        || windowClass == kUtilityWindowClass || windowClass == kFloatingWindowClass) return result;
    frame->origin.x += 1;
    return result;
}

static void SLHookCarbonLayout(SLHookFunctionFn hook)
{
    SLFindSymbolFn find = (SLFindSymbolFn)dlsym(RTLD_DEFAULT, "MSFindSymbol");
    SLGetImageFn image = (SLGetImageFn)dlsym(RTLD_DEFAULT, "MSGetImageByName");
    const void *hitoolbox = image ? image("/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox") : NULL;
    if (!find || !hitoolbox) return;
    void *getWidgetFrame = find(hitoolbox, "__ZN17HIWindowFrameView14GetWidgetFrameEPvmP6CGRect");
    SLHIViewGetWindowRef = find(hitoolbox, "__ZN6HIView12GetWindowRefEv");
    if (!getWidgetFrame || !SLHIViewGetWindowRef) return;
    hook(getWidgetFrame, (void *)sl_getWidgetFrame, (void **)&orig_getWidgetFrame);
}
#else
static void SLHookCarbonLayout(SLHookFunctionFn hook) {}
#endif

// ---- setting up -----------------------------------------------------------------------

// The AppKit part, loaded once the process has AppKit.
static void SLLoadAppKitPart(void)
{
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    NSString *path = [gSLBundlePath stringByAppendingPathComponent:@"Contents/MacOS/SnowLeopardWindows-AppKit"];
    void *image = dlopen([path fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
    SLWindowsAppKitStartFn start = image ? (SLWindowsAppKitStartFn)dlsym(image, SLWindowsAppKitStartSymbol) : NULL;
    if (!start) {
        NSLog(@"SnowLeopardWindows: couldn't load its AppKit part: %s", dlerror());
        return;
    }
    start([gSLBundlePath fileSystemRepresentation], SLRegisterCustomRenderer);
}

// AppKit loaded after the plugin (a Carbon app that loads it later).
static void SLImageAdded(const struct mach_header *header, intptr_t slide)
{
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname || !strstr(info.dli_fname, "/AppKit.framework/")) return;
    dispatch_async(dispatch_get_main_queue(), ^{ SLLoadAppKitPart(); });
}

static BOOL SLAppKitIsLoaded(void)
{
    void *appKit = dlopen("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", RTLD_LAZY | RTLD_NOLOAD);
    if (appKit) dlclose(appKit);
    return appKit != NULL;
}

__attribute__((constructor)) static void SLWindowsStart(void)
{
    @autoreleasepool {
        if (floor(kCFCoreFoundationVersionNumber) != 855) return;      // Mavericks only
        Dl_info info;
        if (!dladdr((void *)SLWindowsStart, &info) || !info.dli_fname) return;
        // .../SnowLeopardWindows.bundle/Contents/MacOS/SnowLeopardWindows
        gSLBundlePath = [[[[[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent]
                           stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] retain];
        SLHookFunctionFn hook = (SLHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
        void *cuiDraw = dlsym(RTLD_DEFAULT, "CUIDraw");
        if (!hook || !cuiDraw) return;
        if (!SLLoadArt()) {
            NSLog(@"SnowLeopardWindows: the bundle's art is missing or unreadable.");
            return;
        }
        hook(cuiDraw, (void *)sl_CUIDraw, (void **)&orig_CUIDraw);
        SLHookCarbonLayout(hook);
        if (SLAppKitIsLoaded()) SLLoadAppKitPart();
        else _dyld_register_func_for_add_image(SLImageAdded);
    }
}
