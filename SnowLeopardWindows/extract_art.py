#!/usr/bin/python
"""Extract Snow Leopard's title bar buttons from Mac OS X 10.6's CoreUI ArtFile.bin.

Usage: extract_art.py /path/to/10.6/ArtFile.bin output.bin [tags.plist]

The art is not part of this repository: extract.sh runs this against a copy of
Snow Leopard (for example its install DVD) and puts the result in build/assets,
which build.sh bundles.

ArtFile.bin (CoreUI, 10.5-10.6):
    header      uint16 fileCount, uint16 maxDepth, uint32 tagCount,
                uint32 tagDescriptorsOffset, uint32 tagNamesOffset,
                uint32 fileDescriptorsOffset, uint32 fileDataOffset
    tag         uint32 nameOffset (into the tag names), uint8 index, 3 bytes pad
    file        uint32 dataOffset (from fileDataOffset), uint8 tags[8] (0-terminated)
    data        0x68-byte header (uint16 type = 1, uint16 count, then x, y,
                w, h as uint16, ...), then premultiplied ARGB pixels, rows top
                to bottom, of an image (w + 2x) wide and (h + x + y) high:
                the button with margins around it.

Output (read by SLWindows.m), little endian:
    "SLWA", uint32 count, then per image:
    uint16 nameLength, name (ASCII), uint16 width, uint16 height,
    width*height*4 bytes premultiplied ARGB.
With a third argument, also writes a property list mapping each name to the
image's ArtFile tags, from which render_hidpi finds the image's recipe.

Names are "<windowtype>/<widget>/<colors>/<state>" using the names Mavericks'
CoreUI uses: windowtype regularwin, utilwin.variant1, utilwin.variant2;
widget titlebarclose (+ "dirty"), titlebarcollapse, titlebarzoom, titlebartoolbar;
colors aqua, graphite or none (untinted); state active, activenokey, inactive, key, disabled,
pressed, rollover, or normal (no state tag).
"""
import plistlib, struct, sys

WIDGETS = {'close': 'titlebarclose', 'closedirty': 'titlebarclosedirty', 'minimize': 'titlebarcollapse',
           'zoom': 'titlebarzoom', 'toolbar': 'titlebartoolbar'}
STATES = ('active', 'activenokey', 'inactive', 'key', 'disabled', 'pressed', 'rollover')


def read_artfile(path):
    d = open(path, 'rb').read()
    nfiles, _, ntags, tagdesc, tagnames, filedesc, filedata = struct.unpack('<HHIIIII', d[:24])
    names = {}
    for i in range(ntags):
        off, idx = struct.unpack('<IB', d[tagdesc + 8 * i: tagdesc + 8 * i + 5])
        names[idx] = d[tagnames + off: d.index('\0', tagnames + off)]
    files = []
    for i in range(nfiles):
        off = struct.unpack('<I', d[filedesc + 12 * i: filedesc + 12 * i + 4])[0]
        tags = set(names.get(ord(c), '') for c in d[filedesc + 12 * i + 4: filedesc + 12 * i + 12] if ord(c))
        files.append((filedata + off, tags))
    return d, files


def image(d, off):
    kind, count, x, y, w, h = struct.unpack('<HHHHHH', d[off:off + 12])
    if kind != 1:
        return None
    width, height = w + 2 * x, h + x + y
    start = off + 0x68
    return width, height, d[start:start + width * height * 4]


def name_for(tags):
    if 'titlebarcontrols' not in tags:
        return None
    if 'regularwin' in tags:
        wtype = 'regularwin'
    elif 'utilwin' in tags and 'variant1' in tags:
        wtype = 'utilwin.variant1'
    elif 'utilwin' in tags and 'variant2' in tags:
        wtype = 'utilwin.variant2'
    else:
        return None
    widgets = [WIDGETS[t] for t in WIDGETS if t in tags]
    if len(widgets) != 1:
        return None
    if 'graphite' in tags:
        colors = 'graphite'
    elif 'colorsryg' in tags or 'colorsrgb' in tags:
        colors = 'aqua'
    else:
        colors = 'none'
    states = [s for s in STATES if s in tags]
    if len(states) > 1:
        return None
    return '%s/%s/%s/%s' % (wtype, widgets[0], colors, states[0] if states else 'normal')


def main():
    d, files = read_artfile(sys.argv[1])
    out = []
    tagmap = {}
    for off, tags in files:
        name = name_for(tags)
        if not name:
            continue
        img = image(d, off)
        if not img:
            continue
        w, h, pixels = img
        if len(pixels) != w * h * 4:
            sys.exit('truncated image %s' % name)
        out.append((name, w, h, pixels))
        tagmap[name] = sorted(tags)
    if not any(n.startswith('regularwin/titlebarclose/aqua/active') for n, _, _, _ in out):
        sys.exit('%s does not look like Snow Leopard\'s ArtFile.bin' % sys.argv[1])
    with open(sys.argv[2], 'wb') as f:
        f.write('SLWA' + struct.pack('<I', len(out)))
        for name, w, h, pixels in sorted(out):
            f.write(struct.pack('<H', len(name)) + name + struct.pack('<HH', w, h) + pixels)
    if len(sys.argv) > 3:
        plistlib.writePlist(tagmap, sys.argv[3])
    print 'Extracted %d title bar button images' % len(out)


if __name__ == '__main__':
    main()
