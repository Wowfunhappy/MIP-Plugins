#!/usr/bin/python
# arrowstrings.py LookPref.nib out.strings
#
# Reads 10.6's "Place scroll arrows:" control from its General preference pane
# (Appearance.prefPane's LookPref.nib, in one language) and writes its text as
# a .strings file for SLPrefPane.m:
#
#   "Place scroll arrows:" = "...";     the label
#   "DoubleMax" = "...";                the "Together" button (tag 1)
#   "Single" = "...";                   the "At top and bottom" button (tag 0)
#
# The nib is loaded with AppKit; the control is found by its outlet
# (placeScrollArrowsMatrix), its buttons by their tags (as 10.6's
# -setScrollArrowVariant: maps them to AppleScrollBarVariant), and its label as
# the text beside it, so nothing depends on the language.
import sys
from Foundation import NSObject, NSURL
from AppKit import NSApplication, NSNib, NSMatrix, NSTextField, NSMaxX, NSMaxY, NSMinX

if len(sys.argv) != 3:
    sys.exit('usage: arrowstrings.py LookPref.nib out.strings')
nib_path, out_path = sys.argv[1], sys.argv[2]


class Owner(NSObject):
    # Stands in for 10.6's LookPref, keeping the one outlet needed. (The nib's
    # other connections fail, harmlessly: AppKit logs "Could not connect...".)
    matrix = None

    def setPlaceScrollArrowsMatrix_(self, value):
        self.matrix = value


NSApplication.sharedApplication()
nib = NSNib.alloc().initWithContentsOfURL_(NSURL.fileURLWithPath_(nib_path))
if nib is None:
    sys.exit('%s: not a nib' % nib_path)
owner = Owner.alloc().init()
# (This PyObjC returns only the result; the outlets are all that's needed.)
ok = nib.instantiateWithOwner_topLevelObjects_(owner, None)
if not ok:
    sys.exit('%s: could not be loaded' % nib_path)

matrix = owner.matrix
if not isinstance(matrix, NSMatrix):
    sys.exit('%s: no placeScrollArrowsMatrix' % nib_path)
titles = {}
for cell in matrix.cells():
    titles[cell.tag()] = cell.title()
if 0 not in titles or 1 not in titles:
    sys.exit('%s: placeScrollArrowsMatrix has no tag 0 and 1 buttons' % nib_path)

# The label: the text field just left of the matrix, level with its first row.
mframe = matrix.frame()
label = None
for view in matrix.superview().subviews():
    if not isinstance(view, NSTextField) or view.isEditable():
        continue
    f = view.frame()
    if NSMaxX(f) > NSMinX(mframe) + 2 or NSMinX(mframe) - NSMaxX(f) > 30:
        continue
    if abs(NSMaxY(f) - NSMaxY(mframe)) > 6:
        continue
    label = view
if label is None:
    sys.exit('%s: no label beside placeScrollArrowsMatrix' % nib_path)


def quote(s):
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')


lines = [u'/* From Mac OS X 10.6\'s General preference pane (LookPref.nib). */',
         u'%s = %s;' % (quote(u'Place scroll arrows:'), quote(label.stringValue())),
         u'%s = %s;' % (quote(u'DoubleMax'), quote(titles[1])),
         u'%s = %s;' % (quote(u'Single'), quote(titles[0]))]
with open(out_path, 'wb') as f:
    f.write((u'\n'.join(lines) + u'\n').encode('utf-16'))
