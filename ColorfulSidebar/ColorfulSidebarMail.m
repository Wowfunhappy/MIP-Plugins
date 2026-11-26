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
//  gets that colour icon instead, at the template's size. Where Mail has none
//  at that size (an account's container mailbox at medium size), its colour
//  icon from the small size is used; the Flagged mailbox at large size, for
//  which Mail has none either, gets Mail's large red flag (FlagRedLarge).
//
//  Trash: Mail's colour icon is the system trash (NSTrashEmpty). Instead, Snow
//  Leopard's Mail trash can (Resources/SnowLeopardTrashMailbox*, copied from
//  Mac OS X 10.6's Mail.app, 16 and 32 pixels): at the small and medium sizes
//  the 16-pixel one, with the 32-pixel one for Retina; at the large size the
//  32-pixel one, with the Finder's trash for Retina.
//

#import <Cocoa/Cocoa.h>
#import "ZKSwizzle.h"

static __thread BOOL gInSidebar;       // set while the sidebar asks for an icon

static NSImageRep *ColorfulSidebarRep(NSString *name, NSString *type)
{
    NSString *path = [[NSBundle bundleForClass:NSClassFromString(@"CVZCSController")] pathForResource:name ofType:type];
    return path ? [NSImageRep imageRepWithContentsOfFile:path] : nil;
}

// Snow Leopard's trash can at `points`: the 16-pixel art (1x) and 32-pixel art
// (2x) at the small and medium sizes; the 32-pixel art (1x) and the Finder's
// trash (2x) at the large size.
static NSImage *ColorfulSidebarTrash(NSUInteger size, NSSize points)
{
    static NSImage *images[3];
    if (size > 2) size = 2;
    if (!images[size]) {
        NSImageRep *small = ColorfulSidebarRep(@"SnowLeopardTrashMailbox", @"png");
        NSImageRep *large = ColorfulSidebarRep(@"SnowLeopardTrashMailboxLarge", @"tiff");
        if (!small || !large) return nil;
        NSImage *image = [[NSImage alloc] initWithSize:points];
        if (size < 2) {
            [small setSize:points];
            [large setSize:points];
            [image addRepresentation:small];
            [image addRepresentation:large];
        } else {
            NSImage *finder = [NSImage imageNamed:NSImageNameTrashEmpty];
            NSImageRep *retina = [finder bestRepresentationForRect:NSMakeRect(0, 0, points.width * 2, points.height * 2) context:nil
                                                             hints:@{ NSImageHintCTM: [NSAffineTransform transform] }];
            [large setSize:points];
            [image addRepresentation:large];
            if (retina) {
                retina = [[retina copy] autorelease];
                [retina setSize:points];
                [image addRepresentation:retina];
            }
        }
        images[size] = image;
    }
    return images[size];
}

static NSImage *ColorfulSidebarSized(NSImage *image, NSSize size)
{
    if (!image || NSEqualSizes([image size], size)) return image;
    image = [[image copy] autorelease];
    [image setSize:size];
    return image;
}

@interface ColorfulSidebar_MailboxesController : NSObject
@end

@implementation ColorfulSidebar_MailboxesController

+ (id)iconForMailbox:(id)mailbox size:(NSUInteger)size style:(NSUInteger)style
{
    NSImage *template = ZKOrig(NSImage *, mailbox, size, style);
    if (!gInSidebar || !(style & 1) || ![template isKindOfClass:[NSImage class]]) return template;

    NSString *name = [template name];
    NSImage *colour = nil;
    if ([name hasPrefix:@"TrashMailbox"]) {
        colour = ColorfulSidebarTrash(size, [template size]);
    } else {
        colour = ZKOrig(NSImage *, mailbox, size, (NSUInteger)0);
        if (![[colour representations] count]) {
            colour = [name hasPrefix:@"FlagsMailbox"] && size == 2 ? [NSImage imageNamed:@"FlagRedLarge"]
                                                                    : ZKOrig(NSImage *, mailbox, (NSUInteger)0, (NSUInteger)0);
        }
    }
    if (![[colour representations] count]) return template;     // Mail has nothing in colour for it
    return ColorfulSidebarSized(colour, [template size]);
}

@end

@interface ColorfulSidebar_MailboxOutlineItemController : NSObject
@end

@implementation ColorfulSidebar_MailboxOutlineItemController

- (void)_updateImage
{
    BOOL outer = gInSidebar;
    gInSidebar = YES;
    ZKOrig(void);
    gInSidebar = outer;
}

- (id)mailboxOutlineItemViewShouldDisplayImage:(id)view
{
    BOOL outer = gInSidebar;
    gInSidebar = YES;
    id result = ZKOrig(id, view);
    gInSidebar = outer;
    return result;
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
}

@end
