//
//  SLWindowsShared.h
//  What SnowLeopardWindows' two executables share (see SLWindowsCore.m): the
//  10.6 art and the drawing made from it (SLWindowsDraw.m, compiled into
//  both), and how the core starts the AppKit part.
//

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

typedef OSStatus (*SLCUIDrawFn)(CFTypeRef renderer, CGRect rect, CGContextRef ctx, CFDictionaryRef options, CFDictionaryRef *result);
typedef void (*SLHookFunctionFn)(void *symbol, void *replacement, void **original);

// SLWindowsDraw.m
extern NSString *gSLBundlePath;                 // the plugin bundle
extern CGColorSpaceRef gColorSpace;             // Generic RGB, as 10.6's CoreUI art
BOOL SLLoadArt(void);
CGImageRef SLArtImage(NSString *name);
CGImageRef SLArt2xImage(NSString *name);
int SLContextScale(CGContextRef ctx);
NSString *SLButtonImageName(NSDictionary *o);
void SLDrawButton(NSString *name, CGRect rect, CGContextRef ctx, BOOL flipped);
double SLSeparatorGray(BOOL active);
void SLFillRow(CGContextRef ctx, CGRect rect, int r, BOOL flipped, double gray);
void SLFillGradient(CGContextRef ctx, CGRect rect, int first, int count, BOOL flipped, double s, double e);
void SLDrawBottomBar(CGRect rect, CGContextRef ctx, NSDictionary *o);
void SLDrawToolbarSeparator(CGRect rect, CGContextRef ctx, NSDictionary *o);
void SLDrawTexturedFrameInto(CGRect rect, CGContextRef ctx, NSDictionary *o, BOOL atop);
void SLDrawTexturedFrame(CGRect rect, CGContextRef ctx, NSDictionary *o);
void SLDrawTitleBar(CGRect rect, CGContextRef ctx, NSDictionary *o);
void SLDrawRegularFrame(CGRect rect, CGContextRef ctx, NSDictionary *o);

// The AppKit part's entry point, in SnowLeopardWindows-AppKit: the core calls
// it with the bundle's path, and the function the AppKit part calls with the
// CoreUI renderer of each non-default NSAppearance (an app's own theme),
// whose drawing the core then leaves alone.
typedef void (*SLRegisterRendererFn)(void *renderer);
typedef void (*SLWindowsAppKitStartFn)(const char *bundlePath, SLRegisterRendererFn registerRenderer);
#define SLWindowsAppKitStartSymbol "SLWindowsAppKitStart"
