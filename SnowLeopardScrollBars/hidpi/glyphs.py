#!/usr/bin/python
"""Sharp arrow triangles for the scroll bar buttons on Retina displays.

Usage: glyphs.py <Extras2.rsrc> <ThemeTable.inc> <output.bin>

Snow Leopard's scroll bar art (AppKit's 'pxm#' pixmaps in HIToolbox's
Extras2.rsrc, which Mavericks still ships) only exists at 1x, and on a Retina
display the plugin draws it scaled up, as 10.6 did. The one part of it that
is plain geometry is the triangle on each arrow button: a black triangle at
some opacity (68% normally, 40% in an inactive window, 89% pressed) over the
button's shading.

For each arrow button pixmap this finds its triangles, paints them out of the
pixmap (the shading around them is constant along the scroll bar, so each
column is interpolated from just beyond the triangle), and fits each triangle
exactly: apex, base and opacity such that drawing it anti-aliased at 1x over
the painted-out pixmap reproduces AppKit's pixels. The 2x version of the
pixmap is then the painted-out pixmap scaled up, with the triangles drawn
over it at 2x. Pixmaps whose fit does not reproduce them closely (the Clear
tint's pressed arrows) are left out, and keep being drawn scaled up.

Output (read by SLArt.m), little endian: "SLSA", uint32 count, then per
image: uint16 name length, name ("<resource ID>/<image index>"), uint16 width,
uint16 height, width*height*4 bytes of premultiplied ARGB.
"""
import re, struct, sys

import numpy as np

# Arrow button pixmaps the plugin draws (ThemeTable.inc): kinds 0x33 / 0x36
# (single arrows / pairs), 0xfb / 0xfe for small scroll bars.
ARROW_KINDS = (0x33, 0x36, 0xfb, 0xfe)


def read_pixmaps(path):
    """AppKit's 'pxm#' pixmaps: {(resource ID, index): premultiplied ARGB float},
    decoded as the plugin does (SLArt.m)."""
    d = open(path, 'rb').read()
    data_off, map_off = struct.unpack('>II', d[:8])
    types = map_off + struct.unpack('>H', d[map_off + 24:map_off + 26])[0]
    out = {}
    for i in range(struct.unpack('>h', d[types:types + 2])[0] + 1):
        t = types + 2 + 8 * i
        if d[t:t + 4] != 'pxm#':
            continue
        refs = types + struct.unpack('>H', d[t + 6:t + 8])[0]
        for j in range(struct.unpack('>H', d[t + 4:t + 6])[0] + 1):
            r = refs + 12 * j
            rid = struct.unpack('>h', d[r:r + 2])[0]
            off = data_off + (struct.unpack('>I', d[r + 4:r + 8])[0] & 0xffffff)
            p = d[off + 4:off + 4 + struct.unpack('>I', d[off:off + 4])[0]]
            version, flags, top, left, bottom, right = struct.unpack('<HHhhhh', p[:12])
            count = struct.unpack('<H', p[0x16:0x18])[0]
            if version != 3 or not flags & 4:
                continue
            w, h = right - left, bottom - top
            mask_rows = ((w + 15) >> 4) * 2
            masks = 1 if flags & 1 else count
            row_bytes = ((32 * w + 15) >> 4) * 2
            for k in range(count):
                start = 0x18 + masks * mask_rows * h + k * row_bytes * h
                rgba = np.array([np.fromstring(p[start + y * row_bytes:start + y * row_bytes + 4 * w], np.uint8).reshape(w, 4)
                                 for y in range(h)], dtype=np.float64)
                out[(rid, k)] = rgba[..., [3, 0, 1, 2]]          # RGBA -> ARGB
    return out


def arrow_pixmaps(theme_table):
    """{(resource ID, index): horizontal} for every arrow button pixmap in ThemeTable.inc."""
    out = {}
    for key, rid, idx in re.findall(r'\{(0x[0-9a-f]+),\s*(\d+),\s*(\d+)\}', open(theme_table).read()):
        key = int(key, 16)
        if key >> 19 in ARROW_KINDS:
            direction = key & 0xff00
            out[(int(rid), int(idx))] = direction in (0x400, 0x500)
    return out


# ---- fitting (vertical orientation: horizontal pixmaps are transposed) ----

SS = 8   # supersampling for coverage


def coverage(tri, shape, scale=1):
    """Fraction of each pixel (at `scale`) inside the triangle (pixmap coordinates)."""
    h, w = shape
    (x1, y1), (x2, y2), (x3, y3) = tri
    ys = (np.arange(h * scale * SS) + 0.5) / (SS * scale)
    xs = (np.arange(w * scale * SS) + 0.5) / (SS * scale)
    X, Y = np.meshgrid(xs, ys)
    def side(ax, ay, bx, by):
        return (bx - ax) * (Y - ay) - (by - ay) * (X - ax)
    d1, d2, d3 = side(x1, y1, x2, y2), side(x2, y2, x3, y3), side(x3, y3, x1, y1)
    inside = ((d1 >= 0) & (d2 >= 0) & (d3 >= 0)) | ((d1 <= 0) & (d2 <= 0) & (d3 <= 0))
    return inside.reshape(h * scale, SS, w * scale, SS).mean(axis=3).mean(axis=1)


def find_glyphs(img):
    """Bounding boxes (y0, y1, x0, x1) of the triangles: compact blobs of
    pixels much darker than the pixels k rows above *and* below them (a
    pressed area or a separator line is not), centred across the button."""
    lum = img[..., 1:].mean(2)
    h, w = lum.shape
    dark = np.zeros((h, w), bool)
    for y in range(h):
        for k in range(4, 9):           # some distance clear of the other triangle of a pair
            a, b = lum[max(0, y - k)], lum[min(h - 1, y + k)]
            dark[y] |= (lum[y] < np.minimum(a, b) - 30) & (img[y, :, 0] > 250)
    dark[:, :2] = dark[:, w - 2:] = False
    seen = np.zeros((h, w), bool)
    boxes = []
    for y in range(h):
        for x in range(w):
            if not dark[y, x] or seen[y, x]:
                continue
            stack, pixels = [(y, x)], []
            seen[y, x] = True
            while stack:
                cy, cx = stack.pop()
                pixels.append((cy, cx))
                for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                    if 0 <= ny < h and 0 <= nx < w and dark[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            ys, xs = [p[0] for p in pixels], [p[1] for p in pixels]
            y0, y1, x0, x1 = min(ys), max(ys) + 1, min(xs), max(xs) + 1
            centred = abs((x0 + x1) / 2.0 - w / 2.0) <= 1.5
            widest = 8 if w >= 15 else 6
            if centred and 2 <= y1 - y0 <= 8 and 3 <= x1 - x0 <= widest and len(pixels) >= 4:
                boxes.append((y0, y1, x0, x1))
    return boxes


def feature_rows(img):
    """Thin lines crossing the button (separator lines): rows whose outer
    columns differ from the rows on both sides of them."""
    lum = img[..., 1:].mean(2)
    h = lum.shape[0]
    rows = np.zeros(h, bool)
    for y in range(1, h - 1):
        for c in (0, -1):
            if abs(lum[y, c] - lum[y - 1, c]) > 8 and abs(lum[y, c] - lum[y + 1, c]) > 8:
                rows[y] = True
    return rows


def paint_out(img, glyphs):
    """The pixmap without its triangles: each column of a triangle's box
    (grown by a pixel) interpolated between the nearest rows beyond it that
    are neither another feature (a separator line) nor a triangle."""
    bg = img.copy()
    h, w = img.shape[:2]
    busy = feature_rows(img)
    for y0, y1, x0, x1 in glyphs:
        busy[y0:y1] = True
    for y0, y1, x0, x1 in glyphs:
        a = y0 - 1
        while a > 0 and busy[a]:
            a -= 1
        b = y1
        while b < h - 1 and busy[b]:
            b += 1
        a, b = max(0, min(a, y0 - 2)), min(h - 1, max(b, y1 + 1))
        while a > 0 and busy[a]:
            a -= 1
        while b < h - 1 and busy[b]:
            b += 1
        for x in range(max(0, x0 - 1), min(w, x1 + 1)):
            for y in range(a + 1, b):
                if busy[y] and not any(g[0] <= y < g[1] for g in glyphs):
                    continue                   # keep separator rows as they are
                t = float(y - a) / (b - a)
                bg[y, x] = img[a, x] * (1 - t) + img[b, x] * t
    return bg


def fit_triangle(img, bg, box):
    """Isosceles triangle pointing up or down: apex x, apex y, base y, half
    width, opacity, so that bg * (1 - opacity * coverage) matches img."""
    y0, y1, x0, x1 = box
    lum, blum = img[..., 1:].mean(2), bg[..., 1:].mean(2)
    region = (slice(max(0, y0 - 1), y1 + 1), slice(max(0, x0 - 1), x1 + 1))
    rows = blum[y0:y1] - lum[y0:y1]
    up = rows[0].sum() < rows[-1].sum()          # widest at the bottom: pointing up

    def error(p, final=False):
        ax, top, bottom, hw = p
        if up:
            tri = ((ax, top), (ax - hw, bottom), (ax + hw, bottom))
        else:
            tri = ((ax - hw, top), (ax + hw, top), (ax, bottom))
        c = coverage(tri, lum.shape)[region]
        b = blum[region]
        # best opacity for this shape: least squares of (b - lum) = alpha * b * c
        num = (b * c * (b - lum[region])).sum()
        den = ((b * c) ** 2).sum()
        alpha = min(1.0, max(0.0, num / den)) if den > 0 else 0
        e = ((b * (1 - alpha * c) - lum[region]) ** 2).mean()
        return (e, tri, alpha) if final else e

    p = [(x0 + x1) / 2.0, float(y0), float(y1), (x1 - x0) / 2.0]
    step = 0.5
    best = error(p)
    while step > 0.01:
        improved = False
        for i in range(4):
            for s in (step, -step):
                q = list(p)
                q[i] += s
                e = error(q)
                if e < best:
                    best, p, improved = e, q, True
        if not improved:
            step /= 2
    return error(p, True)


def process(img):
    glyphs = find_glyphs(img)
    bg = paint_out(img, glyphs)
    tris = []
    for box in glyphs:
        e, tri, alpha = fit_triangle(img, bg, box)
        tris.append((tri, alpha, e))
    return bg, tris


def render(bg, tris, scale):
    """bg (scaled up, bilinearly, as Quartz scales the other pieces) with the
    triangles drawn over it at `scale`."""
    out = bg
    if scale > 1:
        h, w = bg.shape[:2]
        ys = np.clip((np.arange(h * scale) + 0.5) / scale - 0.5, 0, h - 1)
        xs = np.clip((np.arange(w * scale) + 0.5) / scale - 0.5, 0, w - 1)
        y0, x0 = np.floor(ys).astype(int), np.floor(xs).astype(int)
        y1, x1 = np.minimum(y0 + 1, h - 1), np.minimum(x0 + 1, w - 1)
        fy, fx = (ys - y0)[:, None, None], (xs - x0)[None, :, None]
        out = (bg[y0][:, x0] * (1 - fy) * (1 - fx) + bg[y0][:, x1] * (1 - fy) * fx +
               bg[y1][:, x0] * fy * (1 - fx) + bg[y1][:, x1] * fy * fx)
    else:
        out = bg.copy()
    for tri, alpha, e in tris:
        c = coverage(tri, bg.shape[:2], scale)[..., None]
        out = out.copy()
        out[..., 1:] = out[..., 1:] * (1 - alpha * c)
    return out


def main():
    if len(sys.argv) != 4:
        sys.exit('usage: glyphs.py <Extras2.rsrc> <ThemeTable.inc> <output.bin>')
    pixmaps = read_pixmaps(sys.argv[1])
    arrows = arrow_pixmaps(sys.argv[2])
    out = ['SLSA', struct.pack('<I', 0)]
    count = skipped = 0
    for (rid, idx), horizontal in sorted(arrows.items()):
        img = pixmaps.get((rid, idx))
        if img is None:
            continue
        v = np.transpose(img, (1, 0, 2)) if horizontal else img
        bg, tris = process(v)
        error = np.abs(render(bg, tris, 1) - v)[..., 1:]
        if not tris or error.max() > 64 or error.mean() > 2:
            skipped += 1
            continue
        twin = render(bg, tris, 2)
        if horizontal:
            twin = np.transpose(twin, (1, 0, 2))
        h, w = twin.shape[:2]
        name = '%d/%d' % (rid, idx)
        out += [struct.pack('<H', len(name)), name, struct.pack('<HH', w, h),
                np.clip(np.round(twin), 0, 255).astype(np.uint8).tostring()]
        count += 1
    out[1] = struct.pack('<I', count)
    open(sys.argv[3], 'wb').write(''.join(out))
    print 'Drew sharp arrow triangles for %d of %d arrow button images (%d left as they are)' % (count, len(arrows), skipped)


if __name__ == '__main__':
    main()
