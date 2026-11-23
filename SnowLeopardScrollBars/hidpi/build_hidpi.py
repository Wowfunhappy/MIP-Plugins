#!/usr/bin/python
"""Renders 2x versions of the scroll bar art for Retina displays.

Usage: build_hidpi.py <10.6 UI.bundle> <tools dir> <output.bin>

The plugin draws AppKit's 1x scroll bar pixmaps (Extras2.rsrc). Snow Leopard
has no 2x versions of those: 10.6's Cocoa scroll bars were 1x art even in its
Resolution Independence mode. The only Snow Leopard scroll bar art that scales
is CoreUI's (what Carbon applications used), drawn from the resolution-
independent recipes in CoreUI.framework/Resources/UI.bundle. The same design,
with slightly different shading.

So for each AppKit pixmap, pieces.json names the CoreUI state(s) to render and
how to cut and assemble them so the result lines up with the pixmap exactly,
at twice the size (see compose.py). The 2x images are rendered here, at build
time, by Mavericks' own copy of the recipe renderer (render_server.m) from
10.6's recipes, unmodified.

The small arrows' recipes only describe 1x geometry, so their twins are
CoreUI's 1x art scaled up. Pieces not in pieces.json (the Clear-tint pressed
arrows, and track ends AppKit leaves transparent) keep their 1x art.

Output, little endian: "SLSA", uint32 count, then per image: uint16 name
length, name ("<resource ID>/<image index>"), uint16 width, uint16 height,
width*height*4 bytes of premultiplied ARGB.
"""
import json, os, plistlib, shutil, struct, subprocess, sys, tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compose


def load_recipe(ui_bundle, category, tmp):
    """The recipe as a property list (it is stored binary; plistlib reads XML)."""
    xml = os.path.join(tmp, category + '.plist')
    subprocess.check_call(['plutil', '-convert', 'xml1', '-o', xml,
                           os.path.join(ui_bundle, 'Contents', 'Recipes', category + '.xml')])
    return plistlib.readPlist(xml)


def flatten(recipe, category, perm):
    """The properties of one recipe state: the root's, with every subnode's
    overrides along the state's tags applied in turn. None if the tags do not
    lead to exactly one node."""
    tags = set(perm.split('.')) - set([category])
    props = dict(recipe['properties'])
    node, used = recipe, set()
    while True:
        subnodes = node.get('subnodes', {})
        nxt = [k for k in subnodes if k in tags and k not in used]
        if not nxt:
            break
        if len(nxt) > 1:
            return None
        node = subnodes[nxt[0]]
        used.add(nxt[0])
        props.update(node.get('properties', {}))
    return props if used == tags else None


class Renderer(object):
    def __init__(self, ui_bundle, tools, tmp):
        env = dict(os.environ)
        env['DYLD_INSERT_LIBRARIES'] = os.path.join(tools, 'render_cache.dylib')
        self.proc = subprocess.Popen([os.path.join(tools, 'render_server'), ui_bundle],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.tmp = tmp
        self.recipe = load_recipe(ui_bundle, 'scrollbars', tmp)
        self.cache = {}

    def render(self, perm, scale, overrides):
        key = (perm, scale, tuple(sorted(overrides.items())))
        if key in self.cache:
            return self.cache[key]
        props = flatten(self.recipe, 'scrollbars', perm)
        result = None
        if props is not None:
            props.update(overrides)
            path = os.path.join(self.tmp, 'request.plist')
            prefix = os.path.join(self.tmp, 'part')
            plistlib.writePlist({'properties': props}, path)
            self.proc.stdin.write('%s %g %s\n' % (path, scale, prefix))
            self.proc.stdin.flush()
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    raise RuntimeError('render_server exited')
                if line.startswith('@@'):
                    break
            words = line[2:].split()
            if words and words[0] == 'ok':
                result = []
                for i, wh in enumerate(words[1:]):
                    w, h = [int(v) for v in wh.split('x')]
                    data = open('%s_%d.raw' % (prefix, i), 'rb').read()
                    result.append(np.fromstring(data, dtype=np.uint8).reshape(h, w, 4).astype(np.float64))
        self.cache[key] = result
        return result


def main():
    if len(sys.argv) != 4:
        sys.exit('usage: build_hidpi.py <10.6 UI.bundle> <tools dir> <output.bin>')
    ui_bundle, tools, output = sys.argv[1:]
    pieces = json.load(open(os.path.join(HERE, 'pieces.json')))
    tmp = tempfile.mkdtemp(prefix='slscroll')
    try:
        renderer = Renderer(ui_bundle, tools, tmp)
        out = ['SLSA', struct.pack('<I', 0)]
        count = 0
        for name in sorted(pieces):
            spec = pieces[name]
            name = str(name)
            try:
                image = compose.build(spec, renderer.render, 2)
            except ValueError as e:
                sys.stderr.write('build_hidpi: %s: %s\n' % (name, e))
                continue
            h, w = image.shape[:2]
            if [w, h] != [2 * spec['size'][0], 2 * spec['size'][1]]:
                sys.stderr.write('build_hidpi: %s came out %dx%d\n' % (name, w, h))
                continue
            pixels = np.clip(np.round(image), 0, 255).astype(np.uint8)
            out += [struct.pack('<H', len(name)), name, struct.pack('<HH', w, h), pixels.tostring()]
            count += 1
        out[1] = struct.pack('<I', count)
        open(output, 'wb').write(''.join(out))
        renderer.proc.stdin.close()
        renderer.proc.wait()
        print 'Rendered %d of %d scroll bar pieces at 2x' % (count, len(pieces))
        if count < len(pieces):
            sys.exit(1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
