"""Builds 2x versions of AppKit's scroll bar pixmaps from Snow Leopard's CoreUI art.

Each AppKit pixmap the plugin draws (a 'piece') gets a twin at twice the size,
cut and assembled from CoreUI's renderings so that it lines up with the
original exactly. pieces.json says how, per piece; this module does it.
The recipe for a twin is the same at any scale: offsets are in points.

Images are numpy float arrays, premultiplied ARGB, rows top to bottom.
Horizontal pieces are made from CoreUI's *vertical* states, turned on their
side: CoreUI's horizontal art is the same (within a few levels at 1x), and
Mavericks' renderer draws horizontal states badly at 2x (holes, stray white
pixels and dashed outlines, none of which occur in its vertical renderings).

The small arrows' recipes only describe 1x geometry (Mavericks' renderer
returns them at 1x size whatever the scale), so their twins are CoreUI's 1x
art scaled up ('upscale'): as soft as before, but the same art as the sharp
track and thumb next to them.
"""
import numpy as np


def transpose(x):
    return np.transpose(x, (1, 0, 2))


def over(dst, src, y):
    """Composite src over dst with src's first row at row y (clipped)."""
    h = src.shape[0]
    y0, y1 = max(0, y), min(dst.shape[0], y + h)
    if y1 <= y0:
        return
    s = src[y0 - y:y1 - y]
    w = min(dst.shape[1], s.shape[1])
    a = s[:, :w, :1] / 255.0
    dst[y0:y1, :w] = s[:, :w] + dst[y0:y1, :w] * (1 - a)


def strip(parts, length, cap_at_start):
    """A track-like strip `length` rows long: a cap at one end, then the middle part repeated."""
    cap0, mid, cap2 = parts[0], parts[1], parts[2]
    reps = length // mid.shape[0] + 2
    body = np.concatenate([mid] * reps, 0)
    if cap_at_start:
        return np.concatenate([cap0, body], 0)[:length]
    s = np.concatenate([body, cap2], 0)
    return s[s.shape[0] - length:]


def crop(x, start, length):
    """Rows [start, start+length) of x, transparent where outside it."""
    out = np.zeros((length, x.shape[1], 4))
    s0, s1 = max(0, start), min(x.shape[0], start + length)
    if s1 > s0:
        out[s0 - start:s1 - start] = x[s0:s1]
    return out


def upscale(x, factor):
    """Bilinear, pixel centres aligned (as Quartz scales an image up)."""
    h, w = x.shape[:2]
    ys = np.clip((np.arange(h * factor) + 0.5) / factor - 0.5, 0, h - 1)
    xs = np.clip((np.arange(w * factor) + 0.5) / factor - 0.5, 0, w - 1)
    y0 = np.floor(ys).astype(int)
    x0 = np.floor(xs).astype(int)
    y1 = np.minimum(y0 + 1, h - 1)
    x1 = np.minimum(x0 + 1, w - 1)
    fy = (ys - y0)[:, None, None]
    fx = (xs - x0)[None, :, None]
    return (x[y0][:, x0] * (1 - fy) * (1 - fx) + x[y0][:, x1] * (1 - fy) * fx +
            x[y1][:, x0] * fy * (1 - fx) + x[y1][:, x1] * fy * fx)


def build(spec, render, scale):
    """The piece described by spec at `scale` (1 or 2).

    render(perm, scale, overrides) -> list of parts (as rendered), or None.
    The CoreUI states named in spec are vertical ones; for a horizontal piece
    the result is turned on its side."""
    if spec.get('upscale') and scale > 1:
        return upscale(build(spec, render, 1), scale)
    horizontal = spec['horizontal']
    w, h = spec['size']
    length, across = (w, h) if horizontal else (h, w)
    L, A = length * scale, across * scale

    def parts(perm, over_=None):
        ps = render(perm, scale, over_ or {})
        if ps is None:
            raise ValueError('CoreUI could not render %s' % perm)
        return list(ps)

    kind = spec['type']
    if kind == 'arrows':
        out = np.zeros((L, A, 4))
        ap = parts(spec['arrows'])
        if spec.get('pressed'):
            pp = parts(spec['pressed'])
            for i in spec['pressed_parts']:
                ap[i] = pp[i]
        tp = parts(spec['track'])
        T, O = spec['T'] * scale, spec['O'] * scale
        arrows = np.concatenate(ap, 0)
        if spec['at_start']:
            over(out, strip(tp, L - T, True), T)
            over(out, arrows, O)
        else:
            over(out, strip(tp, L - T, False), 0)
            over(out, arrows, L - O - arrows.shape[0])
    elif kind == 'caps':
        # Two halves: the start cap and the end cap of a three-part image.
        p = parts(spec['perm'], spec.get('over'))
        first, second = spec['halves']
        n = 4 * L
        a = crop(strip(p, n, True), spec['a'] * scale, first * scale)
        b = crop(strip(p, n, False), n - (spec['b'] + second) * scale, second * scale)
        out = np.concatenate([a, b], 0)
    elif kind == 'tile':
        # A run of the repeating middle.
        p = parts(spec['perm'], spec.get('over'))
        mid = p[spec.get('part', 1)]
        reps = (spec['offset'] * scale + L) // mid.shape[0] + 2
        out = crop(np.concatenate([mid] * reps, 0), spec['offset'] * scale, L)
    elif kind == 'center':
        # The middle `length` rows of a single-part image.
        p = parts(spec['perm'])[0]
        out = crop(p, (p.shape[0] - L) // 2, L)
    else:
        raise ValueError(kind)
    out = out[:, :A]
    if out.shape[1] < A:
        out = np.concatenate([out, np.zeros((out.shape[0], A - out.shape[1], 4))], 1)
    return transpose(out) if horizontal else out
