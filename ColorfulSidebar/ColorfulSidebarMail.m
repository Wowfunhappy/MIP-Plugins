//
//  ColorfulSidebarMail.m
//  Colour icons in Mail's mailbox sidebar (Mail 7, OS X 10.9).
//
//  Mail picks a mailbox's icon with +[MailboxesController
//  iconForMailbox:size:style:]: size 0, 1, 2 for the small, medium and large
//  sidebar icons (16, 18, 32 points); style bit 0 for the grey template images
//  the sidebar uses (bit 1: selected). Without bit 0 Mail has colour icons of
//  its own, which its menus use: the Snow Leopard-era mailbox art still in
//  Mail.app (InMailbox, SentMailbox...), the system folder and smart folder
//  icons for ordinary and smart mailboxes, coloured flags, and the blue VIP
//  star. While the sidebar (MailboxOutlineItemController) asks for an icon, it
//  gets the colour icon instead, except where that would mean enlarging art:
//
//  - Mail's colour art exists only at 16 and 32 points (1x and 2x), and some
//    of it only at 16. A colour icon is drawn in the template's place keeping
//    its proportions, as large as fits but never larger than its biggest
//    pixel version allows (so shrunk if need be, never enlarged; centred).
//  - On a 2x display, the medium and large sizes would need art Mail doesn't
//    have, so there every mailbox keeps Mail's grey template. Small at 2x and
//    every size at 1x are in colour. The sidebar's window decides which (a row
//    not yet in a window is set up in colour, and set up again when it moves
//    into one or its window's scale changes).
//  - Where Mail has no colour icon at a size, its colour icon from the small
//    size (an account's container mailbox at medium size).
//  - Trash: Snow Leopard's Mail trash can (Resources/SnowLeopardTrashMailbox*,
//    copied from Mac OS X 10.6's Mail.app: 16 pixels, and 32 for 2x), not the
//    system trash Mail uses.
//  - Flagged: Mail's own colour icon (flagged-0) is 13 by 15 points and has
//    no large version; Resources/FlaggedMailbox.tiff (32 points, 1x and 2x) is
//    Mail's large red flag (FlagRedLarge) recoloured to resemble it.
//

#import <Cocoa/Cocoa.h>
#import "ZKSwizzle.h"

static __thread BOOL gInSidebar;       // set while the sidebar asks for an icon
static __thread CGFloat gSidebarScale; // its window's backing scale (0: not in a window yet)

@interface NSObject (ColorfulSidebarMail)
- (id)delegate;
- (NSView *)view;
- (void)_updateImage;
@end

static NSString *ColorfulSidebarResource(NSString *name, NSString *type)
{
    return [[NSBundle bundleForClass:NSClassFromString(@"CVZCSController")] pathForResource:name ofType:type];
}

// Snow Leopard's trash can: 16 points, the 16-pixel art and the 32-pixel art (2x).
static NSImage *ColorfulSidebarTrash(void)
{
    static NSImage *image;
    if (!image) {
        NSString *smallPath = ColorfulSidebarResource(@"SnowLeopardTrashMailbox", @"png");
        NSString *largePath = ColorfulSidebarResource(@"SnowLeopardTrashMailboxLarge", @"tiff");
        NSImageRep *small = smallPath ? [NSImageRep imageRepWithContentsOfFile:smallPath] : nil;
        NSImageRep *large = largePath ? [NSImageRep imageRepWithContentsOfFile:largePath] : nil;
        if (!small || !large) return nil;
        [small setSize:NSMakeSize(16, 16)];
        [large setSize:NSMakeSize(16, 16)];
        NSImage *trash = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        [trash addRepresentation:small];
        [trash addRepresentation:large];
        image = trash;
    }
    return image;
}

static NSImage *ColorfulSidebarFlagged(void)
{
    static NSImage *image;
    if (!image) {
        NSString *path = ColorfulSidebarResource(@"FlaggedMailbox", @"tiff");
        image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    }
    return image;
}

// `image` in a `box`-sized image: keeping its proportions, as large as fits
// but never more pixels than its biggest version has (on the display it is
// drawn on), centred.
static NSImage *ColorfulSidebarFitted(NSImage *image, NSSize box)
{
    NSSize natural = [image size];
    NSInteger widest = 0;
    for (NSImageRep *rep in [image representations]) widest = MAX(widest, [rep pixelsWide]);
    if (natural.width <= 0 || natural.height <= 0 || widest <= 0) return image;
    return [NSImage imageWithSize:box flipped:NO drawingHandler:^BOOL(NSRect rect) {
        CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
        CGFloat scale = ctx ? CGContextGetUserSpaceToDeviceSpaceTransform(ctx).a : 1;
        if (scale <= 0) scale = 1;
        CGFloat fit = MIN(rect.size.width / natural.width, rect.size.height / natural.height);
        CGFloat most = widest / (natural.width * scale);           // beyond this, it would be enlarged
        CGFloat f = MIN(fit, most);
        NSSize drawn = NSMakeSize(natural.width * f, natural.height * f);
        NSRect r = NSMakeRect(rect.origin.x + (rect.size.width - drawn.width) / 2,
                              rect.origin.y + (rect.size.height - drawn.height) / 2, drawn.width, drawn.height);
        [image drawInRect:r fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
        return YES;
    }];
}

@interface ColorfulSidebar_MailboxesController : NSObject
@end

@implementation ColorfulSidebar_MailboxesController

+ (id)iconForMailbox:(id)mailbox size:(NSUInteger)size style:(NSUInteger)style
{
    NSImage *template = ZKOrig(NSImage *, mailbox, size, style);
    if (!gInSidebar || !(style & 1) || ![template isKindOfClass:[NSImage class]]) return template;
    if (gSidebarScale >= 2 && size >= 1) return template;           // no colour art that large

    NSString *name = [template name];
    NSImage *colour;
    if ([name hasPrefix:@"TrashMailbox"]) {
        colour = ColorfulSidebarTrash();
    } else if ([name hasPrefix:@"FlagsMailbox"]) {
        colour = ColorfulSidebarFlagged();
    } else {
        colour = ZKOrig(NSImage *, mailbox, size, (NSUInteger)0);
        if (![[colour representations] count]) colour = ZKOrig(NSImage *, mailbox, (NSUInteger)0, (NSUInteger)0);
    }
    if (![[colour representations] count]) return template;        // nothing in colour for it
    return ColorfulSidebarFitted(colour, [template size]);
}

@end

@interface ColorfulSidebar_MailboxOutlineItemController : NSObject
@end

@implementation ColorfulSidebar_MailboxOutlineItemController

- (void)_updateImage
{
    BOOL outer = gInSidebar;
    CGFloat outerScale = gSidebarScale;
    gInSidebar = YES;
    gSidebarScale = [[[self view] window] backingScaleFactor];
    ZKOrig(void);
    gInSidebar = outer;
    gSidebarScale = outerScale;
}

- (id)mailboxOutlineItemViewShouldDisplayImage:(id)view
{
    BOOL outer = gInSidebar;
    CGFloat outerScale = gSidebarScale;
    gInSidebar = YES;
    gSidebarScale = [[view window] backingScaleFactor];
    id result = ZKOrig(id, view);
    gInSidebar = outer;
    gSidebarScale = outerScale;
    return result;
}

@end

// The sidebar row: its icon is set up again when it moves into a window, or
// its window's scale changes.
@interface ColorfulSidebar_MailboxOutlineItemView : NSView
@end

@implementation ColorfulSidebar_MailboxOutlineItemView

- (void)viewDidMoveToWindow
{
    ZKOrig(void);
    id controller = [(NSObject *)self delegate];
    if ([self window] && [controller respondsToSelector:@selector(_updateImage)]) [controller _updateImage];
}

- (void)viewDidChangeBackingProperties
{
    ZKOrig(void);
    id controller = [(NSObject *)self delegate];
    if ([controller respondsToSelector:@selector(_updateImage)]) [controller _updateImage];
}

@end

@interface ColorfulSidebarMail : NSObject
@end

@implementation ColorfulSidebarMail

+ (void)load
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.mail"]) return;
    ZKSwizzle(ColorfulSidebar_MailboxesController, MailboxesController);
    ZKSwizzle(ColorfulSidebar_MailboxOutlineItemController, MailboxOutlineItemController);
    ZKSwizzle(ColorfulSidebar_MailboxOutlineItemView, MailboxOutlineItemView);
}

@end
