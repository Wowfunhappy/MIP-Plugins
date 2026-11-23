//
//  SLArt.m
//  Snow Leopard scroll bar artwork loader + drawing primitives.
//
//  Snow Leopard's AppKit draws scroll bars from 'pxm#' pixmap resources in
//  HIToolbox's Extras2.rsrc. Mavericks still ships a byte-identical copy of
//  that file, so the artwork is read straight from the system at runtime and
//  nothing of Apple's needs to be bundled with the plugin.
//
//  The resource lookup (ThemeTable.inc) and image construction below mirror
//  AppKit 1038's ReadThemeInfo.m: _GetThemeImage / _NSReadThemeImageFromRsrc.
//
//  Retina: the pixmaps are drawn scaled up, as 10.6 did, except the arrow
//  buttons: SLScrollArt@2x.bin carries a twin at twice the size for each of
//  those, made at build time with the triangle redrawn sharp (see
//  hidpi/glyphs.py). Every drawing primitive below goes through
//  SLDrawImagePart, which draws the twin instead when the context has two or
//  more device pixels per point. Geometry is unchanged: the twin covers
//  exactly what the pixmap would.
//

#import "SLScrollBars.h"

typedef struct { uint32_t key; uint16_t resID; uint16_t index; } SLThemeEntry;

static const SLThemeEntry kThemeTable[] = {
#include "ThemeTable.inc"
};

static NSData *gRsrcData = nil;          // the whole resource file, kept alive forever
static const uint8_t *gRsrc = NULL;
static size_t gRsrcLen = 0;
static uint32_t gDataOffset = 0;
static CFMutableDictionaryRef gPxmOffsets = NULL;   // resID -> offset of resource data
static CFMutableDictionaryRef gImageCache = NULL;   // (resID<<16 | index) -> CGImageRef
static CGColorSpaceRef gColorSpace = NULL;
static CFMutableDictionaryRef gTwinArt = NULL;      // (resID<<16 | index) -> 2x CGImageRef
static CFMutableDictionaryRef gTwinOf = NULL;       // 1x CGImageRef -> its 2x twin

static inline uint32_t BE32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static inline uint16_t BE16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline uint16_t LE16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

// SLScrollArt@2x.bin: "SLSA", uint32 count, then per image uint16 name length,
// name ("<resID>/<index>"), uint16 width, uint16 height, premultiplied ARGB.
static void SLTwinArtLoad(void)
{
    Class cls = objc_getClass("SLScrollBars");
    NSString *path = cls ? [[NSBundle bundleForClass:cls] pathForResource:@"SLScrollArt@2x" ofType:@"bin"] : nil;
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    const uint8_t *d = [data bytes];
    size_t len = [data length], p = 8;
    if (len < 8 || memcmp(d, "SLSA", 4) != 0) return;
    uint32_t count = OSReadLittleInt32(d, 4);

    gTwinArt = CFDictionaryCreateMutable(NULL, count, NULL, &kCFTypeDictionaryValueCallBacks);
    gTwinOf = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    for (uint32_t i = 0; i < count && p + 2 <= len; i++) {
        uint16_t n = OSReadLittleInt16(d, p);
        if (p + 2 + n + 4 > len || n > 31) break;
        char name[32];
        memcpy(name, d + p + 2, n);
        name[n] = 0;
        uint16_t w = OSReadLittleInt16(d, p + 2 + n), h = OSReadLittleInt16(d, p + 4 + n);
        size_t start = p + 6 + n, size = (size_t)w * h * 4;
        if (start + size > len) break;
        int resID, index;
        if (sscanf(name, "%d/%d", &resID, &index) == 2) {
            CFDataRef pixels = CFDataCreate(NULL, d + start, size);
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
            CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, gColorSpace,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big,
                                             provider, NULL, true, kCGRenderingIntentDefault);
            if (image) CFDictionarySetValue(gTwinArt, (void *)(uintptr_t)(((uint32_t)resID << 16) | (index & 0xffff)), image);
            CGImageRelease(image);
            CGDataProviderRelease(provider);
            CFRelease(pixels);
        }
        p = start + size;
    }
}

BOOL SLArtLoad(void)
{
    if (gRsrc) return YES;

    NSString *path = [[NSBundle bundleWithIdentifier:@"com.apple.HIToolbox"] pathForResource:@"Extras2" ofType:@"rsrc"];
    if (!path) path = @"/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Resources/Extras2.rsrc";
    NSData *data = [[NSData alloc] initWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data || [data length] < 256) { [data release]; return NO; }

    const uint8_t *d = [data bytes];
    size_t len = [data length];

    // Classic resource fork layout (big endian).
    uint32_t dataOff = BE32(d), mapOff = BE32(d + 4);
    if (mapOff + 30 > len) { [data release]; return NO; }
    uint32_t typeList = mapOff + BE16(d + mapOff + 24);
    if (typeList + 2 > len) { [data release]; return NO; }
    int typeCount = (int16_t)BE16(d + typeList) + 1;

    CFMutableDictionaryRef offsets = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    for (int i = 0; i < typeCount; i++) {
        const uint8_t *t = d + typeList + 2 + 8 * i;
        if ((size_t)(t - d) + 8 > len) break;
        if (memcmp(t, "pxm#", 4) != 0) continue;
        int resCount = BE16(t + 4) + 1;
        uint32_t refList = typeList + BE16(t + 6);
        for (int j = 0; j < resCount; j++) {
            const uint8_t *r = d + refList + 12 * j;
            if ((size_t)(r - d) + 12 > len) break;
            int16_t resID = (int16_t)BE16(r);
            uint32_t off = BE32(r + 4) & 0x00ffffff;
            CFDictionarySetValue(offsets, (void *)(intptr_t)resID, (void *)(uintptr_t)(dataOff + off));
        }
    }
    if (CFDictionaryGetCount(offsets) == 0) { CFRelease(offsets); [data release]; return NO; }

    gRsrcData = data;
    gRsrc = d;
    gRsrcLen = len;
    gDataOffset = dataOff;
    gPxmOffsets = offsets;
    gImageCache = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    gColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    SLTwinArtLoad();

    // Make sure the pieces every scroll bar needs are really there before we
    // take over any drawing.
    return SLThemeImage(0x32, 0, 0x100, 0, 0, YES) != NULL     // vertical track fill
        && SLThemeImage(0x36, 0, 0x300, 7, 0, NO) != NULL      // vertical double arrows
        && SLThemeImage(0x34, 0, 0x100, 1, 15, NO) != NULL     // vertical blue thumb caps
        && SLThemeImage(0x34, 0, 0x100, 1, 0, YES) != NULL;    // vertical blue thumb fill
}

// _NSReadThemeImageFromRsrc for the only flavour the scroll bar art uses:
// version 3, 32-bit direct pixels (premultiplied RGBA), GenericRGB.
static CGImageRef SLCreatePxmImage(int resID, int index)
{
    uintptr_t off = (uintptr_t)CFDictionaryGetValue(gPxmOffsets, (void *)(intptr_t)resID);
    if (!off || off + 4 > gRsrcLen) return NULL;
    uint32_t resLen = BE32(gRsrc + off);
    const uint8_t *p = gRsrc + off + 4;
    if (off + 4 + resLen > gRsrcLen || resLen < 0x18) return NULL;

    // The pxm# header itself is little endian in Extras2.rsrc.
    unsigned version = LE16(p), flags = LE16(p + 2);
    int top = (int16_t)LE16(p + 4), left = (int16_t)LE16(p + 6), bottom = (int16_t)LE16(p + 8), right = (int16_t)LE16(p + 10);
    unsigned count = LE16(p + 0x16);
    int width = right - left, height = bottom - top;

    if (version != 3 || !(flags & 4)) return NULL;
    if (width <= 0 || height <= 0 || index < 0 || (unsigned)index >= count) return NULL;

    size_t maskRowBytes = ((width + 15) >> 4) * 2;
    size_t maskCount = (flags & 1) ? 1 : count;
    size_t rowBytes = ((32 * (size_t)width + 15) >> 4) * 2;
    size_t imageBytes = rowBytes * height;
    size_t start = 0x18 + maskCount * maskRowBytes * height + (size_t)index * imageBytes;
    if (start + imageBytes > resLen) return NULL;

    CFDataRef pixels = CFDataCreate(NULL, p + start, imageBytes);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CFRelease(pixels);
    CGImageRef image = CGImageCreate(width, height, 8, 32, rowBytes, gColorSpace,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
                                     provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

CGImageRef SLThemeImage(int kind, int state, int dir, int tint, int index, BOOL pattern)
{
    if (!gPxmOffsets) return NULL;

    uint32_t key = ((uint32_t)kind << 19) + (pattern ? 0x2000 : 0) + state + dir;
    if (tint > 0) key += (uint32_t)(tint - 1) << 16;

    for (size_t i = 0; i < sizeof(kThemeTable) / sizeof(kThemeTable[0]); i++) {
        if (kThemeTable[i].key != key) continue;
        int resID = kThemeTable[i].resID;
        int imageIndex = kThemeTable[i].index + index;
        void *cacheKey = (void *)(uintptr_t)(((uint32_t)resID << 16) | (imageIndex & 0xffff));
        CGImageRef image = (CGImageRef)CFDictionaryGetValue(gImageCache, cacheKey);
        if (!image) {
            image = SLCreatePxmImage(resID, imageIndex);
            if (image) {
                CFDictionarySetValue(gImageCache, cacheKey, image);   // cache owns it
                CGImageRef twin = gTwinArt ? (CGImageRef)CFDictionaryGetValue(gTwinArt, cacheKey) : NULL;
                if (twin && CGImageGetWidth(twin) == 2 * CGImageGetWidth(image) && CGImageGetHeight(twin) == 2 * CGImageGetHeight(image))
                    CFDictionarySetValue(gTwinOf, image, twin);
            }
        }
        return image;
    }
    return NULL;
}

NSSize SLImageSize(CGImageRef image)
{
    return image ? NSMakeSize(CGImageGetWidth(image), CGImageGetHeight(image)) : NSZeroSize;
}

static CGContextRef SLContext(void)
{
    return (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
}

// Equivalent of -[NSImage _compositeFlipped:inRect:fromRect:operation:fraction:]
// with NSCompositeSourceOver. `src` is in the image's own coordinates
// (origin bottom-left); `dst` is the rectangle the piece should cover in the
// current (possibly flipped) coordinate system. The piece is drawn upright.
void SLDrawImagePart(CGImageRef image, NSRect src, NSRect dst, BOOL flipped)
{
    if (!image || NSIsEmptyRect(src) || NSIsEmptyRect(dst)) return;
    CGContextRef ctx = SLContext();
    if (!ctx) return;

    CGFloat h = CGImageGetHeight(image);
    CGRect crop = CGRectMake(src.origin.x, h - NSMaxY(src), src.size.width, src.size.height);

    // On a Retina display (two or more device pixels per point), the 2x twin.
    CGImageRef twin = gTwinOf ? (CGImageRef)CFDictionaryGetValue(gTwinOf, image) : NULL;
    if (twin) {
        CGAffineTransform m = CGContextGetUserSpaceToDeviceSpaceTransform(ctx);
        if (sqrt(m.a * m.a + m.b * m.b) >= 1.5 && sqrt(m.c * m.c + m.d * m.d) >= 1.5) {
            image = twin;
            crop = CGRectMake(2 * crop.origin.x, 2 * crop.origin.y, 2 * crop.size.width, 2 * crop.size.height);
        }
    }
    CGImageRef piece = CGImageCreateWithImageInRect(image, crop);
    if (!piece) return;

    CGContextSaveGState(ctx);
    if (flipped) {
        CGContextTranslateCTM(ctx, 0, NSMaxY(dst));
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(dst.origin.x, 0, dst.size.width, dst.size.height), piece);
    } else {
        CGContextDrawImage(ctx, NSRectToCGRect(dst), piece);
    }
    CGContextRestoreGState(ctx);
    CGImageRelease(piece);
}

// Equivalent of -[NSImage _compositeFlipped:atPoint:fromRect:NSZeroRect ...]:
// the whole image at natural size with its lower-left corner at `point`
// (which, in a flipped view, is the visually-lower-left corner).
void SLDrawImageAtPoint(CGImageRef image, NSPoint point, BOOL flipped)
{
    NSSize size = SLImageSize(image);
    NSRect dst = flipped ? NSMakeRect(point.x, point.y - size.height, size.width, size.height)
                         : NSMakeRect(point.x, point.y, size.width, size.height);
    SLDrawImagePart(image, NSMakeRect(0, 0, size.width, size.height), dst, flipped);
}

// Equivalent of _NSTileImage(patternColor, flipped, rect, offset, 1.0).
//
// AppKit fills `rect` with a pattern colour whose phase is set so that the
// pattern cell's origin sits at rect's origin, shifted back by `offset`. The
// visible result in a flipped view is that the image pixel (offset.x,
// offset.y), counted from the image's top-left, lands on rect's top-left
// corner. Tiling by hand gives the same pixels without depending on the
// window's base transform, so it also behaves in layer-backed views.
void SLTileImage(CGImageRef image, NSRect rect, NSPoint offset, BOOL flipped)
{
    if (!image || NSIsEmptyRect(rect)) return;
    CGContextRef ctx = SLContext();
    if (!ctx) return;

    NSSize size = SLImageSize(image);
    CGFloat ox = fmod(offset.x, size.width), oy = fmod(offset.y, size.height);
    if (ox < 0) ox += size.width;
    if (oy < 0) oy += size.height;

    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, NSRectToCGRect(rect));
    NSRect full = NSMakeRect(0, 0, size.width, size.height);
    if (flipped) {
        for (CGFloat y = NSMinY(rect) - oy; y < NSMaxY(rect); y += size.height)
            for (CGFloat x = NSMinX(rect) - ox; x < NSMaxX(rect); x += size.width)
                SLDrawImagePart(image, full, NSMakeRect(x, y, size.width, size.height), YES);
    } else {
        // Unflipped: rect's origin is its bottom-left and the cell origin is
        // the image's bottom-left.
        for (CGFloat y = NSMinY(rect) - oy; y < NSMaxY(rect); y += size.height)
            for (CGFloat x = NSMinX(rect) - ox; x < NSMaxX(rect); x += size.width)
                SLDrawImagePart(image, full, NSMakeRect(x, y, size.width, size.height), NO);
    }
    CGContextRestoreGState(ctx);
}

// AppKit 1038's Draw3PartImage(combined, caps, caps, fill, vertical, flipped,
// rect, NSCompositeSourceOver, fraction 1.0): the cap image is split in half
// and drawn at the two ends, the fill is tiled between them.
void SLDrawThreePart(CGImageRef caps, CGImageRef fill, NSRect rect, BOOL vertical, BOOL flipped)
{
    NSSize capSize = SLImageSize(caps);
    NSRect first, second, middle;

    if (vertical) {
        // "first" is the lower half of the image (image coords), drawn at the
        // NSMaxYEdge; "second" is the upper half, drawn at the NSMinYEdge.
        CGFloat h1 = ceil(0.5 * capSize.height), h2 = floor(0.5 * capSize.height);
        NSRect src1 = NSMakeRect(0, 0, capSize.width, h1);
        NSRect src2 = NSMakeRect(0, capSize.height - h2, capSize.width, h2);
        if (h1 + h2 > rect.size.height) {
            h1 = rect.size.height / (h1 + h2) * h1;
            h2 = rect.size.height - h1;
        }
        if (capSize.width > 0) {
            rect = NSInsetRect(rect, (rect.size.width - capSize.width) * 0.5, 0);
            rect.origin.x = floor(rect.origin.x);
        }
        NSDivideRect(rect, &first, &middle, h1, NSMaxYEdge);
        NSDivideRect(middle, &second, &middle, h2, NSMinYEdge);
        SLDrawImagePart(caps, src1, first, flipped);
        SLDrawImagePart(caps, src2, second, flipped);
    } else {
        CGFloat w1 = ceil(0.5 * capSize.width), w2 = floor(0.5 * capSize.width);
        NSRect src1 = NSMakeRect(0, 0, w1, capSize.height);
        NSRect src2 = NSMakeRect(capSize.width - w2, 0, w2, capSize.height);
        if (w1 + w2 > rect.size.width) {
            w1 = rect.size.width / (w1 + w2) * w1;
            w2 = rect.size.width - w1;
        }
        if (capSize.height > 0) {
            rect = NSInsetRect(rect, 0, (rect.size.height - capSize.height) * 0.5);
            rect.origin.y = floor(rect.origin.y);
        }
        NSDivideRect(rect, &first, &middle, w1, NSMinXEdge);
        NSDivideRect(middle, &second, &middle, w2, NSMaxXEdge);
        SLDrawImagePart(caps, src1, first, flipped);
        SLDrawImagePart(caps, src2, second, flipped);
    }
    SLTileImage(fill, middle, NSZeroPoint, flipped);
}
