//
//  SLWindowsDraw.m
//  10.6's title bar art and the drawing made from it: the buttons, title
//  bars, unified toolbars, bottom bars and textured windows (see
//  SLWindowsCore.m for the values). Compiled into both of SnowLeopardWindows'
//  executables (SLWindowsShared.h).
//

#import "SLWindowsShared.h"
#import <libkern/OSByteOrder.h>

NSString *gSLBundlePath;
static CFDictionaryRef gArt;            // image name -> CGImageRef
static CFDictionaryRef gArt2x;          // the same at 2x, for Retina displays
CGColorSpaceRef gColorSpace;

// ---- art ------------------------------------------------------------------------

static CFDictionaryRef SLReadArtFile(NSString *resource)
{
    NSString *path = [[gSLBundlePath stringByAppendingPathComponent:@"Contents/Resources"]
                         stringByAppendingPathComponent:[resource stringByAppendingPathExtension:@"bin"]];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    const uint8_t *d = [data bytes];
    size_t len = [data length], p = 8;
    if (len < 8 || memcmp(d, "SLWA", 4) != 0) return NULL;
    uint32_t count = OSReadLittleInt32(d, 4);

    CFMutableDictionaryRef art = CFDictionaryCreateMutable(NULL, count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (uint32_t i = 0; i < count; i++) {
        if (p + 2 > len) break;
        uint16_t nameLength = OSReadLittleInt16(d, p);
        if (p + 2 + nameLength + 4 > len) break;
        CFStringRef name = CFStringCreateWithBytes(NULL, d + p + 2, nameLength, kCFStringEncodingASCII, false);
        uint16_t w = OSReadLittleInt16(d, p + 2 + nameLength), h = OSReadLittleInt16(d, p + 4 + nameLength);
        size_t start = p + 6 + nameLength, size = (size_t)w * h * 4;
        if (start + size > len || !name) { if (name) CFRelease(name); break; }

        // Premultiplied ARGB, as CoreUI stores it.
        CFDataRef pixels = CFDataCreate(NULL, d + start, size);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
        CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, gColorSpace,
                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big,
                                         provider, NULL, false, kCGRenderingIntentDefault);
        if (image) CFDictionarySetValue(art, name, image);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CFRelease(pixels);
        CFRelease(name);
        p = start + size;
    }
    return art;
}

// SLWindowArt.bin: 10.6's 1x images. SLWindowArt@2x.bin: the same images at
// 2x, rendered by extract.sh from 10.6's recipes (render_hidpi.m).
BOOL SLLoadArt(void)
{
    if (gArt) return gArt2x && CFDictionaryGetCount(gArt) > 0;
    gColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    gArt = SLReadArtFile(@"SLWindowArt");
    gArt2x = SLReadArtFile(@"SLWindowArt@2x");
    return gArt && gArt2x && CFDictionaryGetCount(gArt) > 0;
}

CGImageRef SLArtImage(NSString *name)
{
    return (CGImageRef)CFDictionaryGetValue(gArt, (CFStringRef)name);
}

CGImageRef SLArt2xImage(NSString *name)
{
    return (CGImageRef)CFDictionaryGetValue(gArt2x, (CFStringRef)name);
}


// ---- title bar buttons --------------------------------------------------------------

NSString *SLButtonImageName(NSDictionary *o)
{
    NSString *widget = o[@"widget"];
    NSString *windowType = o[@"windowtype"] ?: @"regularwin";
    if ([windowType isEqualToString:@"kCUIWindowTypeTextured"]) windowType = @"regularwin";
    if ([widget isEqualToString:@"titlebarclose"] && [o[@"value"] intValue] != 0) widget = @"titlebarclosedirty";
    // Aqua or Graphite, as the control tint is chosen (AppleAquaColorVariant: 6 is Graphite).
    Boolean valid = false;
    CFIndex variant = CFPreferencesGetAppIntegerValue(CFSTR("AppleAquaColorVariant"), kCFPreferencesCurrentApplication, &valid);
    NSString *colors = (valid && variant == 6) ? @"graphite" : @"aqua";

    NSString *state = o[@"state"];
    NSString *presentation = o[@"kCUIPresentationStateKey"];
    NSArray *states;
    if ([state isEqualToString:@"disabled"]) states = @[@"disabled"];
    else if ([state isEqualToString:@"pressed"]) states = @[@"pressed"];
    else if ([state isEqualToString:@"rollover"]) states = @[@"rollover"];
    // (AppKit says a window is inactive in kCUIPresentationStateKey; Carbon,
    // HIToolbox, in "state".)
    else if ([presentation isEqualToString:@"kCUIPresentationStateInactive"] || [state isEqualToString:@"inactive"]) states = @[@"inactive"];
    else if ([presentation isEqualToString:@"kCUIPresentationStateActiveMain"]) states = @[@"activenokey", @"active"];
    else states = @[@"active", @"key", @"normal"];

    for (NSString *s in states) {
        NSString *name = [NSString stringWithFormat:@"%@/%@/%@/%@", windowType, widget, colors, s];
        if (SLArtImage(name)) return name;
    }
    return nil;
}

void SLDrawButton(NSString *name, CGRect rect, CGContextRef ctx, BOOL flipped)
{
    CGImageRef image = SLArtImage(name);
    CGFloat w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    // On a Retina display, the 2x rendering of the same image in the same place.
    CGImageRef image2x = SLContextScale(ctx) >= 2 ? SLArt2xImage(name) : NULL;
    if (image2x && CGImageGetWidth(image2x) == 2 * w && CGImageGetHeight(image2x) == 2 * h) image = image2x;
    // 10.6's images include the button's shadow; centre horizontally, top aligned.
    CGFloat x = rect.origin.x + floor((rect.size.width - w) / 2);
    CGFloat top = MAX(0, floor((rect.size.height - h) / 2));
    CGContextSaveGState(ctx);
    if (flipped) {
        CGContextTranslateCTM(ctx, x, rect.origin.y + top + h);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    } else {
        CGContextDrawImage(ctx, CGRectMake(x, CGRectGetMaxY(rect) - top - h, w, h), image);
    }
    CGContextRestoreGState(ctx);
}

// ---- title bar background -----------------------------------------------------------------

double SLSeparatorGray(BOOL active)
{
    return active ? 63 : 135;
}

void SLFillRow(CGContextRef ctx, CGRect rect, int r, BOOL flipped, double gray)
{
    CGFloat v = round(gray) / 255;
    CGFloat components[] = { v, v, v, 1 };
    CGColorRef color = CGColorCreate(gColorSpace, components);
    CGContextSetFillColorWithColor(ctx, color);
    CGColorRelease(color);
    CGFloat y = flipped ? rect.origin.y + r : CGRectGetMaxY(rect) - 1 - r;
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, y, rect.size.width, 1));
}

// Device pixels per point vertically (2 on Retina displays).
int SLContextScale(CGContextRef ctx)
{
    CGAffineTransform m = CGContextGetUserSpaceToDeviceSpaceTransform(ctx);
    double scale = sqrt(m.c * m.c + m.d * m.d);
    return scale >= 1.5 ? (int)lround(scale) : 1;
}

// 10.6's cubic gradient from s to e over `count` point rows starting at
// row `first`, evaluated at the centre of every device pixel row.
void SLFillGradient(CGContextRef ctx, CGRect rect, int first, int count, BOOL flipped, double s, double e)
{
    int scale = SLContextScale(ctx), n = count * scale;
    double D = s - e;
    for (int j = 0; j < n; j++) {
        double t = (j + 0.5) / n;
        CGFloat v = round(D * t * t * t - 1.5 * D * t * t - 0.5 * D * t + s) / 255;
        CGFloat components[] = { v, v, v, 1 };
        CGColorRef color = CGColorCreate(gColorSpace, components);
        CGContextSetFillColorWithColor(ctx, color);
        CGColorRelease(color);
        CGFloat h = 1.0 / scale, offset = first + (CGFloat)j / scale;
        CGFloat y = flipped ? rect.origin.y + offset : CGRectGetMaxY(rect) - offset - h;
        CGContextFillRect(ctx, CGRectMake(rect.origin.x, y, rect.size.width, h));
    }
}

void SLDrawBottomBar(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL active = ![o[@"state"] isEqualToString:@"inactive"];
    BOOL separator = [o[@"kCUIWindowFrameDrawBottomBarSeparatorKey"] boolValue];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    int rows = (int)lround(rect.size.height);
    int n = rows - (separator ? 1 : 0);
    if (n < 1) return;
    double s = active ? 191 : 229, e = active ? 150 : 207;
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    if (separator) SLFillRow(ctx, rect, 0, flipped, SLSeparatorGray(active));
    SLFillGradient(ctx, rect, separator ? 1 : 0, n, flipped, s, e);
    CGContextRestoreGState(ctx);
}

void SLDrawToolbarSeparator(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL active = ![o[@"kCUIPresentationStateKey"] isEqualToString:@"kCUIPresentationStateInactive"];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    // The line is the toolbar's last row.
    SLFillRow(ctx, rect, (int)lround(rect.size.height) - 1, flipped, SLSeparatorGray(active));
}

void SLDrawTexturedFrameInto(CGRect rect, CGContextRef ctx, NSDictionary *o, BOOL atop)
{
    BOOL active = ![o[@"state"] isEqualToString:@"inactive"];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    int rows = (int)lround(rect.size.height);
    int top = MIN(rows, (int)lround([o[@"kCUIWindowFrameUnifiedTitleBarHeightKey"] doubleValue]));
    int barHeight = (int)lround([o[@"kCUIWindowFrameBottomBarHeightKey"] doubleValue]);
    int bottom = MIN(rows - top, barHeight > 0 ? barHeight : 10);
    double flat = active ? 150 : 207;
    double ts = active ? 197 : 233;
    double bs = barHeight > 0 ? (active ? 191 : 229) : flat, be = barHeight > 0 ? (active ? 150 : 207) : flat - 25;

    CGContextSaveGState(ctx);
    if (atop) CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    CGFloat v = flat / 255, components[] = { v, v, v, 1 };
    CGColorRef color = CGColorCreate(gColorSpace, components);
    CGContextSetFillColorWithColor(ctx, color);
    CGColorRelease(color);
    CGContextFillRect(ctx, rect);
    if (top > 1) {
        SLFillRow(ctx, rect, 0, flipped, ts + 0.4 * (255 - ts));
        SLFillGradient(ctx, rect, 1, top - 1, flipped, ts, flat);
    }
    if (bottom > 0) SLFillGradient(ctx, rect, rows - bottom, bottom, flipped, bs, be);
    CGContextRestoreGState(ctx);
}

void SLDrawTexturedFrame(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    SLDrawTexturedFrameInto(rect, ctx, o, YES);
}

void SLDrawTitleBar(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL active = ![o[@"state"] isEqualToString:@"inactive"];
    BOOL separator = [o[@"kCUIWindowFrameDrawTitleSeparatorKey"] boolValue];
    BOOL flipped = [o[@"is.flipped"] boolValue];
    int rows = (int)lround(rect.size.height);
    int n = rows - 1 - (separator ? 1 : 0);
    if (n < 1) return;

    double s = active ? 197 : 233, e = active ? 150 : 207;
    double highlight = s + 0.4 * (255 - s);

    CGContextSaveGState(ctx);
    // Only where CoreUI has just drawn the title bar, so the window keeps its
    // rounded corners and outline.
    CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    SLFillRow(ctx, rect, 0, flipped, highlight);
    SLFillGradient(ctx, rect, 1, n, flipped, s, e);
    for (int r = n + 1; r < rows; r++) SLFillRow(ctx, rect, r, flipped, SLSeparatorGray(active));
    CGContextRestoreGState(ctx);
}

// A standard window's frame. AppKit asks for its title bar (and unified
// toolbar) alone; a Carbon window (HIToolbox) asks for the whole window at
// once, saying how tall its title bar and unified toolbar are
// (kCUIWindowFrameUnifiedTitleBarHeightKey) and its bottom bar
// (kCUIWindowFrameBottomBarHeightKey). Then the title bar gradient goes over
// the top that tall, and the bottom bar's (as AppKit's bottom bars get it,
// with its separator if asked for) over the bottom; the window's body between
// them is CoreUI's, as in AppKit's windows.
void SLDrawRegularFrame(CGRect rect, CGContextRef ctx, NSDictionary *o)
{
    BOOL flipped = [o[@"is.flipped"] boolValue];
    CGFloat height = rect.size.height;
    CGFloat top = round([o[@"kCUIWindowFrameUnifiedTitleBarHeightKey"] doubleValue]);
    if (top <= 0 || top >= height) {
        SLDrawTitleBar(rect, ctx, o);
        return;
    }
    // Rows count from the top: in a flipped context the top is the rectangle's minimum y.
    CGRect title = rect;
    title.size.height = top;
    if (!flipped) title.origin.y = CGRectGetMaxY(rect) - top;
    SLDrawTitleBar(title, ctx, o);

    CGFloat bottom = round([o[@"kCUIWindowFrameBottomBarHeightKey"] doubleValue]);
    if (bottom > 0 && top + bottom <= height) {
        CGRect bar = rect;
        bar.size.height = bottom;
        if (flipped) bar.origin.y = CGRectGetMaxY(rect) - bottom;
        SLDrawBottomBar(bar, ctx, o);
    }
}
