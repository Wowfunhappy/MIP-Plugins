//
//  CVZCSController.m
//  ColorfulSidebar
//
//  Created by cvz. on 12/07/23.
//  Copyright 2012 cvz. All rights reserved.
//	ColorfulSidebar is released under the MIT License.
//	http://opensource.org/licenses/mit-license.php
//

#import "CVZCSController.h"
#import <objc/runtime.h>

static NSDictionary *CVZCSgIconMappingDict = nil;
static BOOL CVZCSgInstalled = NO;

// MIP port: the icon table is built on first use, not in +load - MIP loads
// the bundle while the app is checking in with LaunchServices, and building
// it asks LaunchServices for icons (NSWorkspace).
static NSDictionary *CVZCSfIconMappingDict(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[NSClassFromString(@"CVZCSController") performSelector:@selector(setUpIconMappingDict)];
	});
	return CVZCSgIconMappingDict;
}

void CVZCSfSwizzleInstanceMethod (Class cls, SEL old, SEL new) {
	Method mold = class_getInstanceMethod(cls, old);
	Method mnew = class_getInstanceMethod(cls, new);
	if (mold && mnew) {
		if (class_addMethod(cls, old, method_getImplementation(mold), method_getTypeEncoding(mold))) {
			mold = class_getInstanceMethod(cls, old);
		}
		if (class_addMethod(cls, new, method_getImplementation(mnew), method_getTypeEncoding(mnew))) {
			mnew = class_getInstanceMethod(cls, new);
		}
		method_exchangeImplementations(mold, mnew);
	}
}

void CVZCSfSwizzleClassMethod (Class cls, SEL old, SEL new) {
	Method mold = class_getClassMethod(cls, old);
	Method mnew = class_getClassMethod(cls, new);
	if (mold && mnew) {
		Class metaCls = objc_getMetaClass(class_getName(cls));
		if (class_addMethod(metaCls, old, method_getImplementation(mold), method_getTypeEncoding(mold))) {
			mold = class_getClassMethod(cls, old);
		}
		if (class_addMethod(metaCls, new, method_getImplementation(mnew), method_getTypeEncoding(mnew))) {
			mnew = class_getClassMethod(cls, new);
		}
		method_exchangeImplementations(mold, mnew);
	}
}

struct TFENode {
    struct OpaqueNodeRef *fNodeRef;
};

@interface NSObject (CVZCS)

- (NSString *)path;
- (NSURL *)URL;
- (NSString *)name;
- (BOOL)isAlias;
- (id)getNodeAsResolvedNode:(BOOL)arg1;

+ (id)nodeFromNodeRef:(struct OpaqueNodeRef *)nodeRef;
- (struct OpaqueIconRef *)createAlternativeIconRepresentationWithOptions:(id)arg1;

@end

@implementation NSObject (CVZCSColorfulSidebar)

- (void)CVZCSm_new_TSidebarItemCell_drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{	
	NSRect rect = [(NSCell *)self imageRectForBounds:cellFrame];
	if (!NSIsEmptyRect(rect)) {
		SEL aSEL = @selector(accessibilityAttributeNames);
		if ([self respondsToSelector:aSEL] && [[self performSelector:aSEL] containsObject:NSAccessibilityURLAttribute]) {
			NSURL *aURL = [self accessibilityAttributeValue:NSAccessibilityURLAttribute];
			NSImage *image = nil;
			if ([aURL isFileURL]) {
				NSString *path = [aURL path];
				image = [CVZCSfIconMappingDict() objectForKey:path];
				if (!image) {
					aSEL = @selector(name);
					if ([self respondsToSelector:aSEL]) {
						image = [CVZCSfIconMappingDict() objectForKey:[self performSelector:aSEL]];
					}
				}
				if (!image) {
					image = [[NSWorkspace sharedWorkspace] iconForFile:path];
				}
			} else {
				image = [CVZCSfIconMappingDict() objectForKey:[aURL absoluteString]];
			}
			if (!image) {
				aSEL = @selector(name);
				if ([self respondsToSelector:aSEL]) {
					image = [CVZCSfIconMappingDict() objectForKey:[self performSelector:aSEL]];
				}
			}
			if (!image) {
				aSEL = @selector(image);
				if ([self respondsToSelector:aSEL]) {
					NSImage *sidebarImage = [self performSelector:aSEL];
					aSEL = @selector(sourceImage);
					if ([sidebarImage respondsToSelector:aSEL]) {
						sidebarImage = [sidebarImage performSelector:aSEL];
					}
					if ([sidebarImage name]) {
						image = [CVZCSfIconMappingDict() objectForKey:[sidebarImage name]];
					}
					// Tags
					if (!image) {
						if ([[sidebarImage representations] count] == 1) {
							image = [self performSelector:@selector(image)];
						}
					}
				}
			}
			if (!image) {
				Class cls = NSClassFromString(@"FINode");
				if ([cls respondsToSelector:@selector(nodeFromNodeRef:)] && [[self class] respondsToSelector:@selector(nodeForItem:)]) {
					struct TFENode *node = (struct TFENode *)[[self class] performSelector:@selector(nodeForItem:) withObject:self];
					id finode = [cls nodeFromNodeRef:node->fNodeRef];
					if ([finode respondsToSelector:@selector(createAlternativeIconRepresentationWithOptions:)]) {
						IconRef iconRef = [finode createAlternativeIconRepresentationWithOptions:nil];
						image = [[[NSImage alloc] initWithIconRef:iconRef] autorelease];
						ReleaseIconRef(iconRef);
					}
				}
			}
			
			if (image) {
				NSImageCell *imageCell;
				object_getInstanceVariable(self, "_imageCell", (void **)&imageCell);
				[imageCell setImage:image];
			}
		}
	}
	
	[self CVZCSm_new_TSidebarItemCell_drawWithFrame:cellFrame inView:controlView];
}

+ (void)CVZCSm_new_TSidebarItemCell_initialize
{
	if ([[self className] isEqualToString:@"FI_TSidebarItemCell"]) {
		if (!CVZCSgInstalled) {
			CVZCSgInstalled = YES;
			SEL old = @selector(drawWithFrame:inView:);
			SEL new = @selector(CVZCSm_new_TSidebarItemCell_drawWithFrame:inView:);
			CVZCSfSwizzleInstanceMethod(self, old, new);
		}
	}
	[self CVZCSm_new_TSidebarItemCell_initialize];
}

- (NSImage *)CVZCSm_new_NSNavFBENode_sidebarIcon
{
	if (![self respondsToSelector:@selector(path)]
		|| ![self respondsToSelector:@selector(URL)]
		|| ![self respondsToSelector:@selector(name)]
		|| ![self respondsToSelector:@selector(isAlias)]
		|| ![self respondsToSelector:@selector(getNodeAsResolvedNode:)]) {
		return [self CVZCSm_new_NSNavFBENode_sidebarIcon];
	}
	
	NSImage *colorImage = nil;
	
	NSString *path = [self path];
	if ([path isAbsolutePath]) {
		colorImage = [CVZCSfIconMappingDict() objectForKey:path];
		if (colorImage) {
			return colorImage;
		}
		colorImage = [CVZCSfIconMappingDict() objectForKey:[self name]];
		if (colorImage) {
			return colorImage;
		}
		colorImage = [[NSWorkspace sharedWorkspace] iconForFile:path];
		if (colorImage) {
			return colorImage;
		}
	}
	
	if ([self isAlias]) {
		self = [self getNodeAsResolvedNode:YES];
	}
	
	SEL aSEL = @selector(isComputerNode);
	if ([self respondsToSelector:aSEL] && [self performSelector:aSEL]) {
		return [NSImage imageNamed:NSImageNameComputer];
	}
	
	colorImage = [CVZCSfIconMappingDict() objectForKey:[[self URL] absoluteString]];
	if (colorImage) {
		return colorImage;
	}
	
	colorImage = [CVZCSfIconMappingDict() objectForKey:[self name]];
	if (colorImage) {
		return colorImage;
	}
	
	aSEL = @selector(icon);
	if ([self respondsToSelector:aSEL]) {
		colorImage = [self performSelector:aSEL];
		if (colorImage) {
			return colorImage;
		}
	}
	
	return [self CVZCSm_new_NSNavFBENode_sidebarIcon];
}

- (NSImage *)CVZCSm_new_NSNavMediaNode_sidebarIcon
{
	NSImage *image = [self CVZCSm_new_NSNavMediaNode_sidebarIcon];
	NSImage *colorImage = [CVZCSfIconMappingDict() objectForKey:[image name]];
	if (colorImage) {
		image = colorImage;
	}
	return image;
}

@end

@implementation CVZCSController

+ (void)load
{
	if (NSAppKitVersionNumber < 1138) {
		return;
	}
	if (!CVZCSgInstalled) {
		Class cls;
		SEL old, new;
		cls = NSClassFromString(@"TSidebarItemCell");
		if (cls) {
			CVZCSgInstalled = YES;
			old = @selector(drawWithFrame:inView:);
			new = @selector(CVZCSm_new_TSidebarItemCell_drawWithFrame:inView:);
			CVZCSfSwizzleInstanceMethod(cls, old, new);
			
			cls = NSClassFromString(@"NSNavFBENode");
			old = @selector(sidebarIcon);
			new = @selector(CVZCSm_new_NSNavFBENode_sidebarIcon);
			CVZCSfSwizzleInstanceMethod(cls, old, new);
			
			cls = NSClassFromString(@"NSNavMediaNode");
			old = @selector(sidebarIcon);
			new = @selector(CVZCSm_new_NSNavMediaNode_sidebarIcon);
			CVZCSfSwizzleInstanceMethod(cls, old, new);
			
		} else {
			cls = NSClassFromString(@"FI_TSidebarItemCell");
			if (cls) {
				CVZCSgInstalled = YES;
				old = @selector(drawWithFrame:inView:);
				new = @selector(CVZCSm_new_TSidebarItemCell_drawWithFrame:inView:);
				CVZCSfSwizzleInstanceMethod(cls, old, new);
			} else {
				cls = [NSTextFieldCell class];
				old = @selector(initialize);
				new = @selector(CVZCSm_new_TSidebarItemCell_initialize);
				CVZCSfSwizzleClassMethod(cls, old, new);
			}
		}
	}
}

+ (void)setUpIconMappingDict
{
	NSString *path = [[NSBundle bundleForClass:self] pathForResource:@"icons" ofType:@"plist"];
	NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
	if (!dict) {
		CVZCSgIconMappingDict = [NSDictionary new];
	} else {
		NSMutableDictionary *mdict = [NSMutableDictionary dictionaryWithCapacity:0];
		for (NSString *key in dict) {
			NSImage *image;
			if ([key isAbsolutePath]) {
				image = [[[NSImage alloc] initWithContentsOfFile:key] autorelease];
			} else if ([key length] == 4) {
				OSType code = UTGetOSTypeFromString((CFStringRef)key);
				image = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(code)];
			} else {
				image = [NSImage imageNamed:key];
				if (image && [key rangeOfString:@"NSMediaBrowserMediaType"].length) {
					image = [[image copy] autorelease];
					NSSize size = NSMakeSize(32, 32);
					[image setSize:size];
					[[[image representations] lastObject] setSize:size];
				}
			}
			
			if (image) {
				NSArray *arr = [dict objectForKey:key];
				for (key in arr) {
					if ([key hasPrefix:@"~"]) {
						key = [key stringByExpandingTildeInPath];
					}
					[mdict setObject:image forKey:key];
				}
			}
		}
		CVZCSgIconMappingDict = [mdict copy];
	}
}
@end
