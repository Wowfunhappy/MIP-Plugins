//
//  KeynoteScrollPresentation.m
//  Keynote presentations: a notched scroll wheel moves between slides (and
//  clicks don't); the slide in view is announced to other apps; and with
//  "Allow Mission Control, Dashboard and others to use displays" on, a
//  presentation in a full-screen space keeps the Dock and menu bar.
//
//  Keynote's classes are in its executable, so they exist when MIP loads
//  this, early in Keynote's launch.
//

#import <AppKit/AppKit.h>
#import "ZKSwizzle.h"
#import <objc/runtime.h>

// Notification sent when the current slide changes during presentation
// userInfo contains:
//   @"slideUniqueIdentifier" - NSString, stable identifier for the slide (persists across sessions)
static NSString *const KeynoteSlideDidChangeNotification = @"KeynoteSlideDidChangeNotification";

@interface NSObject (KeynotePrivateMethods)
- (id)movieRendererAtPoint:(NSPoint)point;
- (BOOL)p_mouseEventIsInHyperlink:(NSEvent *)event hitObject:(id *)hitObject hitRep:(id *)hitRep hitInfo:(id *)hitInfo;

// KNPlaybackController methods
- (BOOL)isNonMovieAnimationActive;

// KNSlideNode methods
- (NSString *)uniqueIdentifier;

// KNMacPlaybackPresentationController methods
- (BOOL)p_isCoveringFullScreenDocumentWindow;
- (void)stopPresentation;

// KNMacDocumentWindowController methods
- (id)playbackPresentationController;
@end

@interface KeynoteScrollPresentation_KNMacAnimatedPlaybackContainerView : NSView @end
@implementation KeynoteScrollPresentation_KNMacAnimatedPlaybackContainerView

static BOOL preventNavigation = YES;
static NSTimeInterval lastScrollTime = 0;
static const NSTimeInterval scrollDebounceInterval = 0.01; // debounce

// Prevent clicking to go to the next slide (unless it's from us)
- (void)mouseDown:(NSEvent *)theEvent {
	if (! preventNavigation) {
		preventNavigation = YES;
		ZKOrig(void, theEvent);
	}
	return;
}

- (void)rightMouseDown:(NSEvent *)theEvent {
	if (! preventNavigation) {
		preventNavigation = YES;
		ZKOrig(void, theEvent);
	}
	return;
}

// Add scroll wheel support for slide navigation. (Only discrete/notched scroll wheels)
- (void)scrollWheel:(NSEvent *)event {
	BOOL isDiscrete = ![event hasPreciseScrollingDeltas];
	if (!isDiscrete) {
		return;
	}
	
	CGFloat deltaY = [event scrollingDeltaY];
	if (fabs(deltaY) < 0.1) {
		return;
	}
	
	// Ignore scroll during slide transitions
	id playbackController = object_getIvar(self, class_getInstanceVariable([self class], "mPlaybackController"));
	if ([playbackController isNonMovieAnimationActive]) {
		return;
	}
	
	NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
	if (currentTime - lastScrollTime < scrollDebounceInterval) {
		return;
	}
	
	// Update last scroll time
	lastScrollTime = currentTime;
	
	if (deltaY > 0) {
		preventNavigation = NO;
		[self rightMouseDown:nil];
		
	} else if (deltaY < 0) {
		preventNavigation = NO;
		[self mouseDown:nil];
	}
}

@end


// Swizzle KNPlaybackSession to post notifications on slide change
// Used by Wacom Overlay app, could potentially be used by other apps.
@interface KeynoteScrollPresentation_KNPlaybackSession : NSObject @end
@implementation KeynoteScrollPresentation_KNPlaybackSession

- (void)p_setCurrentSlideNode:(id)slideNode {
	// Call original implementation first
	ZKOrig(void, slideNode);

	if (!slideNode) {
		return;
	}

	// Get slide identifier
	NSString *uniqueIdentifier = [slideNode uniqueIdentifier];
	if (!uniqueIdentifier) {
		return;
	}

	// Build userInfo dictionary
	NSDictionary *userInfo = @{@"slideUniqueIdentifier": uniqueIdentifier};

	// Post notification via distributed notification center for cross-app communication
	[[NSDistributedNotificationCenter defaultCenter]
		postNotificationName:KeynoteSlideDidChangeNotification
		object:nil
		userInfo:userInfo
		deliverImmediately:YES];
}

@end


// Allow Dock and menu bar to appear during presentation, if presenting in a fullscreen space.
@interface KeynoteScrollPresentation_KNMacPlaybackPresentationController : NSObject @end
@implementation KeynoteScrollPresentation_KNMacPlaybackPresentationController

- (NSApplicationPresentationOptions)p_applicationPresentationOptions {
	NSApplicationPresentationOptions orig = (NSApplicationPresentationOptions)ZKOrig(NSApplicationPresentationOptions);

	// Only modify when the "Allow Mission Control..." preference is enabled
	if (![[NSUserDefaults standardUserDefaults] boolForKey:@"KNPlaybackPresentationAllowSystemScreenOverlays"]) {
		return orig;
	}

	// Only modify when presenting in a fullscreen space
	if (![self p_isCoveringFullScreenDocumentWindow]) {
		return orig;
	}

	// Remove HideDock (fullscreen spaces auto-hide dock anyway)
	if (orig & NSApplicationPresentationHideDock) {
		orig &= ~NSApplicationPresentationHideDock;
	}

	// Remove HideMenuBar (fullscreen spaces auto-hide menu bar anyway)
	if (orig & NSApplicationPresentationHideMenuBar) {
		orig &= ~NSApplicationPresentationHideMenuBar;
	}

	return orig;
}

- (void)p_suspendPresentation {	
	if (
		[self p_isCoveringFullScreenDocumentWindow] &&
		[[NSUserDefaults standardUserDefaults] boolForKey:@"KNPlaybackPresentationAllowSystemScreenOverlays"]
	) {
		return;
	}
	
	ZKOrig(void);
}

@end


// End presentation when exiting fullscreen via menu bar (which no longer auto hides per above).
@interface KeynoteScrollPresentation_KNMacDocumentWindowController : NSObject @end
@implementation KeynoteScrollPresentation_KNMacDocumentWindowController

- (void)windowWillExitFullScreen:(NSNotification *)notification {
	id presentationController = [self playbackPresentationController];
	if (presentationController && [presentationController p_isCoveringFullScreenDocumentWindow]) {
		[presentationController stopPresentation];
	}
	ZKOrig(void, notification);
}

@end


@interface KeynoteScrollPresentation : NSObject @end
@implementation KeynoteScrollPresentation

+ (void)load {
	ZKSwizzle(KeynoteScrollPresentation_KNMacAnimatedPlaybackContainerView, KNMacAnimatedPlaybackContainerView);
	ZKSwizzle(KeynoteScrollPresentation_KNPlaybackSession, KNPlaybackSession);
	ZKSwizzle(KeynoteScrollPresentation_KNMacPlaybackPresentationController, KNMacPlaybackPresentationController);
	ZKSwizzle(KeynoteScrollPresentation_KNMacDocumentWindowController, KNMacDocumentWindowController);
}

@end