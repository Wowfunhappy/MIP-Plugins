//
//  render_hidpi.m
//  Build-time tool: renders Snow Leopard's title bar buttons at 2x.
//
//  Snow Leopard shipped its control art twice: as bitmaps for 1x in
//  ArtFile.bin, and as "recipes" (CoreUI.framework/Resources/UI.bundle), the
//  resolution-independent descriptions those bitmaps were made from. With
//  Resolution Independence turned on (a UI scale factor other than 1), 10.6's
//  CoreUI rendered controls from the recipes, through QuartzCore's
//  ScalableUserInterface framework, at whatever scale was asked for.
//
//  Mavericks still ships ScalableUserInterface. This tool feeds it 10.6's
//  recipes and renders every title bar button image that extract_art.py took
//  from ArtFile.bin, at 1x and 2x. The 1x renders are compared with the
//  ArtFile images to show that the recipe reproduces them; the 2x renders are
//  written out for the plugin.
//
//  Two workarounds:
//   - ScalableUserInterface refuses to render without the window server's
//     shared artwork cache, which Mavericks no longer has: CGSSharedArtworkCache()
//     returns NULL and the cache functions do nothing. render_hidpi_cache.c
//     (inserted with DYLD_INSERT_LIBRARIES by extract.sh) returns a dummy
//     pointer instead, which is only ever passed back to those no-op functions.
//   - Mavericks' ScalableUserInterface measures a recipe's subnodes as empty.
//     A subnode only overrides some of its parent's properties, so each image
//     is given its own recipe file holding the root's properties with every
//     override along its path applied, and rendered as a root.
//
//  Usage: render_hidpi <10.6 UI.bundle> <tags.plist> <SLWindowArt.bin> <output.bin>
//  Output uses SLWindowArt.bin's format (see extract_art.py), with the same
//  names and the images at twice the size.
//

#import <Cocoa/Cocoa.h>
#import <dlfcn.h>

typedef struct _QSIContext *QSIContextRef;
typedef struct _QSIElement *QSIElementRef;
static QSIContextRef (*QSIOpenBundle)(CFURLRef);
static QSIElementRef (*QSICreateElement)(QSIContextRef, CFStringRef, int, int, float);
typedef struct { long rows, columns; } QSIDimension;     // returned in registers
static QSIDimension (*QSIElementGetDimension)(QSIElementRef);
static CGImageRef (*QSIElementGetImage)(QSIElementRef, int, int);
static void (*QSIReleaseElement)(QSIElementRef);

static NSString *const kCategory = @"titlebarcontrols";

static void Fail(NSString *message)
{
    fprintf(stderr, "render_hidpi: %s\n", message.UTF8String);
    exit(1);
}

// SLWindowArt.bin: name -> NSData of premultiplied ARGB, plus sizes.
static NSDictionary *ReadArt(NSString *path, NSMutableDictionary *sizes)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    const uint8_t *d = data.bytes;
    size_t len = data.length, p = 8;
    if (len < 8 || memcmp(d, "SLWA", 4) != 0) Fail([NSString stringWithFormat:@"%@ is not an SLWindowArt file", path]);
    uint32_t count = OSReadLittleInt32(d, 4);
    NSMutableDictionary *art = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < count && p + 2 <= len; i++) {
        uint16_t n = OSReadLittleInt16(d, p);
        NSString *name = [[NSString alloc] initWithBytes:d + p + 2 length:n encoding:NSASCIIStringEncoding];
        uint16_t w = OSReadLittleInt16(d, p + 2 + n), h = OSReadLittleInt16(d, p + 4 + n);
        size_t start = p + 6 + n, size = (size_t)w * h * 4;
        if (start + size > len) break;
        art[name] = [NSData dataWithBytes:d + start length:size];
        sizes[name] = [NSValue valueWithSize:NSMakeSize(w, h)];
        p = start + size;
    }
    return art;
}

// The image's recipe: the root's properties with each override along the path
// given by its tags applied in turn. Returns nil if a tag matches no node.
static NSDictionary *FlattenedRecipe(NSDictionary *root, NSArray *tags, NSString **path)
{
    NSMutableSet *remaining = [NSMutableSet setWithArray:tags];
    [remaining removeObject:kCategory];
    NSMutableDictionary *props = [root[@"properties"] mutableCopy];
    NSMutableArray *steps = [NSMutableArray array];
    NSDictionary *node = root;
    for (;;) {
        NSDictionary *subnodes = node[@"subnodes"];
        NSString *next = nil;
        for (NSString *key in subnodes) {
            if ([remaining containsObject:key]) {
                if (next) return nil;       // ambiguous
                next = key;
            }
        }
        if (!next) break;
        node = subnodes[next];
        [props addEntriesFromDictionary:node[@"properties"]];
        [remaining removeObject:next];
        [steps addObject:next];
    }
    *path = [steps componentsJoinedByString:@"/"];
    return remaining.count ? nil : @{ @"properties": props };
}

// Premultiplied ARGB bytes of an image, drawn at its own size.
static NSData *ARGBData(CGImageRef image)
{
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    NSMutableData *data = [NSMutableData dataWithLength:w * h * 4];
    // The renderer's images are device RGB; draw them untransformed (same
    // space) so the bytes are exactly what it rendered.
    CGColorSpaceRef space = CGImageGetColorSpace(image);
    CGContextRef ctx = CGBitmapContextCreate(data.mutableBytes, w, h, 8, w * 4, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
    if (!ctx) return nil;
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);
    return data;
}

static CGImageRef Render(QSIContextRef context, NSString *category, float scale)
{
    QSIElementRef element = QSICreateElement(context, (CFStringRef)category, 0, 0, scale);
    if (!element) return NULL;
    QSIDimension dim = QSIElementGetDimension(element);
    CGImageRef image = dim.rows == 1 && dim.columns == 1 ? CGImageRetain(QSIElementGetImage(element, 0, 0)) : NULL;
    QSIReleaseElement(element);
    return image;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 5) Fail(@"usage: render_hidpi <10.6 UI.bundle> <tags.plist> <SLWindowArt.bin> <output.bin>");
        NSString *uiBundle = @(argv[1]);
        NSDictionary *tagMap = [NSDictionary dictionaryWithContentsOfFile:@(argv[2])];
        NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
        NSDictionary *art1x = ReadArt(@(argv[3]), sizes);
        if (!tagMap.count) Fail(@"no tags");

        void *sui = dlopen("/System/Library/Frameworks/QuartzCore.framework/Versions/A/Frameworks/ScalableUserInterface.framework/Versions/A/ScalableUserInterface", RTLD_NOW);
        QSIOpenBundle = dlsym(sui, "QSIOpenBundle");
        QSICreateElement = dlsym(sui, "QSICreateElement");
        QSIElementGetDimension = dlsym(sui, "QSIElementGetDimension");
        QSIElementGetImage = dlsym(sui, "QSIElementGetImage");
        QSIReleaseElement = dlsym(sui, "QSIReleaseElement");
        if (!QSIOpenBundle || !QSICreateElement || !QSIElementGetDimension || !QSIElementGetImage || !QSIReleaseElement)
            Fail(@"ScalableUserInterface.framework not found (this needs OS X 10.9)");
        void *(*artworkCache)(void) = dlsym(RTLD_DEFAULT, "CGSSharedArtworkCache");
        if (!artworkCache || !artworkCache()) Fail(@"run with DYLD_INSERT_LIBRARIES=render_hidpi_cache.dylib (see extract.sh)");

        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *recipe = [NSPropertyListSerialization propertyListWithData:
            [NSData dataWithContentsOfFile:[uiBundle stringByAppendingPathComponent:@"Contents/Recipes/titlebarcontrols.xml"]]
            options:0 format:NULL error:NULL];
        if (![recipe isKindOfClass:[NSDictionary class]]) Fail(@"titlebarcontrols recipe not found in the UI.bundle");

        // A scratch copy of the UI.bundle: its property lists, a link to its
        // resources (the materials and glyphs the recipes use), and one recipe
        // per image.
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"render_hidpi.%d/UI.bundle", getpid()]];
        NSString *contents = [tmp stringByAppendingPathComponent:@"Contents"];
        [fm removeItemAtPath:[tmp stringByDeletingLastPathComponent] error:NULL];
        [fm createDirectoryAtPath:[contents stringByAppendingPathComponent:@"Recipes"] withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *file in @[@"Info.plist", @"id.plist", @"taxonomy.plist", @"version.plist"]) {
            NSString *src = [uiBundle stringByAppendingPathComponent:[@"Contents" stringByAppendingPathComponent:file]];
            if ([fm fileExistsAtPath:src]) [fm copyItemAtPath:src toPath:[contents stringByAppendingPathComponent:file] error:NULL];
        }
        [fm createSymbolicLinkAtPath:[contents stringByAppendingPathComponent:@"Resources"]
                 withDestinationPath:[uiBundle stringByAppendingPathComponent:@"Contents/Resources"] error:NULL];

        NSArray *names = [[tagMap allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSMutableDictionary *categories = [NSMutableDictionary dictionary];
        int index = 0;
        for (NSString *name in names) {
            NSString *path = nil;
            NSDictionary *flat = FlattenedRecipe(recipe, tagMap[name], &path);
            if (!flat) { fprintf(stderr, "render_hidpi: no recipe node for %s\n", name.UTF8String); continue; }
            NSString *category = [NSString stringWithFormat:@"slw%03d", index++];
            NSData *plist = [NSPropertyListSerialization dataWithPropertyList:flat format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            [plist writeToFile:[contents stringByAppendingPathComponent:[NSString stringWithFormat:@"Recipes/%@.xml", category]] atomically:YES];
            categories[name] = category;
        }

        NSMutableData *out = [NSMutableData dataWithBytes:"SLWA\0\0\0\0" length:8];
        uint32_t written = 0;
        int worst = 0;
        NSString *worstName = nil;
        for (NSString *name in names) {
            NSString *category = categories[name];
            if (!category) continue;
            NSSize size = [sizes[name] sizeValue];
            // A fresh context for every image: the renderer caches elements
            // per context, keyed on only 16 bits of the path's hash, so
            // different recipes can otherwise come back as an earlier rendering.
            QSIContextRef context = QSIOpenBundle((CFURLRef)[NSURL fileURLWithPath:tmp]);
            if (!context) Fail(@"could not open the UI.bundle");
            CGImageRef one = Render(context, category, 1), two = Render(context, category, 2);
            // (Not closed: QSICloseBundle crashes here. This process is short-lived.)
            if (!one || !two || CGImageGetWidth(one) != size.width || CGImageGetHeight(one) != size.height ||
                CGImageGetWidth(two) != 2 * size.width || CGImageGetHeight(two) != 2 * size.height) {
                fprintf(stderr, "render_hidpi: %s did not render at the expected size (%gx%g: %zux%zu, %zux%zu)\n", name.UTF8String,
                        size.width, size.height, one ? CGImageGetWidth(one) : 0, one ? CGImageGetHeight(one) : 0,
                        two ? CGImageGetWidth(two) : 0, two ? CGImageGetHeight(two) : 0);
                CGImageRelease(one); CGImageRelease(two);
                continue;
            }
            // How closely the recipe reproduces 10.6's 1x image.
            NSData *mine = ARGBData(one), *theirs = art1x[name];
            const uint8_t *a = mine.bytes, *b = theirs.bytes;
            int diff = 0;
            for (NSUInteger i = 0; i < theirs.length && i < mine.length; i++) diff = MAX(diff, abs((int)a[i] - (int)b[i]));
            if (diff > worst) { worst = diff; worstName = name; }

            NSData *pixels = ARGBData(two);
            uint16_t n = OSSwapHostToLittleInt16((uint16_t)name.length);
            uint16_t w = OSSwapHostToLittleInt16((uint16_t)CGImageGetWidth(two)), h = OSSwapHostToLittleInt16((uint16_t)CGImageGetHeight(two));
            [out appendBytes:&n length:2];
            [out appendData:[name dataUsingEncoding:NSASCIIStringEncoding]];
            [out appendBytes:&w length:2];
            [out appendBytes:&h length:2];
            [out appendData:pixels];
            written++;
            CGImageRelease(one); CGImageRelease(two);
        }
        uint32_t count = OSSwapHostToLittleInt32(written);
        [out replaceBytesInRange:NSMakeRange(4, 4) withBytes:&count];
        [fm removeItemAtPath:[tmp stringByDeletingLastPathComponent] error:NULL];

        if (written == 0) Fail(@"nothing rendered");
        if (![out writeToFile:@(argv[4]) atomically:YES]) Fail(@"could not write the output");
        printf("Rendered %u of %lu title bar button images at 2x (1x renders within %d levels of 10.6's%s%s)\n",
               written, (unsigned long)names.count, worst, worstName ? "; worst: " : "", worstName ? worstName.UTF8String : "");
    }
    return 0;
}
