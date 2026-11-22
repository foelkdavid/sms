#!/usr/bin/env python3
"""Preview integration checks: visible X11/XTest + Pillow for screenshot assertions.
Run c3c build && python3 tests/preview.py. All settings/fixtures are temporary.
"""
import ctypes as c
import ctypes.util
import json
import os
from pathlib import Path
import struct
import shutil
import subprocess
import tempfile
import time
import zlib
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
x = c.CDLL(ctypes.util.find_library('X11'))
xt = c.CDLL(ctypes.util.find_library('Xtst'))
x.XOpenDisplay.restype = c.c_void_p
d = x.XOpenDisplay(None)
assert d, 'visible X11 display required'
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
root = x.XDefaultRootWindow(d)
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_char_p)]
x.XFree.argtypes = [c.c_void_p]
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)]
x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
x.XFlush.argtypes = [c.c_void_p]
x.XWarpPointer.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_int, c.c_int]
x.XTranslateCoordinates.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_int, c.c_int, c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_ulong)]
x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
x.XKeysymToKeycode.restype = c.c_uint
xt.XTestFakeMotionEvent.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_ulong]
xt.XTestFakeButtonEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
xt.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]


def find(window, pid):
    name = c.c_char_p()
    x.XFetchName(d, window, c.byref(name))
    match = name.value == b'sms'
    if name:
        x.XFree(name)
    if match:
        kind, fmt, count, remaining, data = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong(), c.c_void_p()
        atom = x.XInternAtom(d, b'_NET_WM_PID', True)
        x.XGetWindowProperty(d, window, atom, 0, 1, False, 0, c.byref(kind), c.byref(fmt), c.byref(count), c.byref(remaining), c.byref(data))
        try:
            if data and count.value and c.cast(data, c.POINTER(c.c_ulong))[0] == pid:
                return window
        finally:
            if data:
                x.XFree(data)
    r, parent, n = c.c_ulong(), c.c_ulong(), c.c_uint()
    children = c.POINTER(c.c_ulong)()
    if not x.XQueryTree(d, window, c.byref(r), c.byref(parent), c.byref(children), c.byref(n)):
        return None
    try:
        for i in range(n.value):
            result = find(children[i], pid)
            if result:
                return result
    finally:
        if children:
            x.XFree(children)


def click(window, row):
    rx, ry, child = c.c_int(), c.c_int(), c.c_ulong()
    x.XTranslateCoordinates(d, window, root, 260, 95 + 54 * row, c.byref(rx), c.byref(ry), c.byref(child))
    if os.environ.get('HYPRLAND_INSTANCE_SIGNATURE') and shutil.which('hyprctl'):
        # Xwayland cannot warp the compositor's pointer using XTest alone.
        clients = json.loads(subprocess.check_output(['hyprctl', 'clients', '-j']))
        client = next(client for client in clients if client['pid'] == active_pid)
        px, py = client['at']
        subprocess.run(['hyprctl', 'dispatch', 'movecursor', f'{px + 260} {py + 95 + 54 * row}'], check=True, stdout=subprocess.DEVNULL)
    else:
        xt.XTestFakeMotionEvent(d, -1, rx.value, ry.value, 0)
    x.XWarpPointer(d, 0, window, 0, 0, 0, 0, 260, 95 + 54 * row)
    x.XFlush(d)
    time.sleep(.1)
    for down in (True, False):
        xt.XTestFakeButtonEvent(d, 1, down, 0)
        x.XFlush(d)
        time.sleep(.04)


def backspace():
    for down in (True, False):
        xt.XTestFakeKeyEvent(d, x.XKeysymToKeycode(d, 0xff08), down, 0)
        x.XFlush(d)
        time.sleep(.06)


def png(path, w, h, rgba):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    compressor = zlib.compressobj()
    row = b'\0' + bytes(rgba) * w
    compressed = b''.join(compressor.compress(row) for _ in range(h)) + compressor.flush()
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', compressed) + chunk(b'IEND', b''))


with tempfile.TemporaryDirectory(prefix='sms-preview-test-') as temp:
    temp = Path(temp)
    folder = temp / 'files'
    folder.mkdir()
    png(folder / 'a-wide.png', 3200, 1600, (240, 80, 40, 255))
    png(folder / 'b-tall.PNG', 200, 700, (30, 120, 240, 255))
    (folder / 'c-broken.png').write_text('broken image')
    (folder / 'd-text.txt').write_text('hello')
    (folder / 'e-too-large.png').write_bytes((ROOT / 'bmu/dev/fixtures/image-too-many-pixels.png').read_bytes())
    png(folder / 'f-alpha.png', 400, 400, (240, 80, 40, 128))
    Image.new('RGB', (600, 400), (70, 210, 90)).save(folder / 'g-photo.jpg')
    env = dict(os.environ, XDG_CONFIG_HOME=str(temp / 'config'))

    def run(name, action):
        global active_pid
        shot = '/tmp/sms-preview-' + name + '.png'
        process = subprocess.Popen([str(ROOT / 'build/sms'), '-d', str(folder), '--scale', '1', '--frames', '180', '--shot', shot], env=env)
        active_pid = process.pid
        try:
            deadline = time.monotonic() + 2
            window = None
            while time.monotonic() < deadline and not window:
                time.sleep(.05)
                window = find(root, process.pid)
            assert window
            time.sleep(.4)  # XID creation precedes mapping; do not focus an unmapped window.
            if os.environ.get('HYPRLAND_INSTANCE_SIGNATURE') and shutil.which('hyprctl'):
                subprocess.run(['hyprctl', 'dispatch', 'focuswindow', f'pid:{process.pid}'], check=True, stdout=subprocess.DEVNULL)
            x.XSetInputFocus(d, window, 1, 0)
            x.XFlush(d)
            time.sleep(.6)
            action(window)
            assert process.wait(timeout=15) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        return Image.open(shot).convert('RGB')

    def preview_pixels(image):
        w = min(360, (image.width - 200) * .45)
        return image.crop((int(image.width - w), 120, image.width - 20, image.height - 70))

    def count(image, color):
        return sum(n for n, pixel in image.getcolors(image.width * image.height) if pixel == color)

    wide = run('wide', lambda w: click(w, 1))
    assert count(preview_pixels(wide), (240, 80, 40)) > 10000
    tall = run('rapid-tall', lambda w: (click(w, 1), click(w, 2)))
    assert count(preview_pixels(tall), (30, 120, 240)) > 10000
    assert count(preview_pixels(tall), (240, 80, 40)) == 0
    broken = run('broken', lambda w: click(w, 3))
    assert count(preview_pixels(broken), (29, 32, 33)) > 10000
    hidden = run('non-image', lambda w: (click(w, 1), click(w, 4)))
    assert count(preview_pixels(hidden), (29, 32, 33)) == 0
    limited = run('too-large', lambda w: click(w, 5))
    assert count(preview_pixels(limited), (29, 32, 33)) > 10000
    alpha = run('alpha', lambda w: click(w, 6))
    assert count(preview_pixels(alpha), (240, 80, 40)) == 0
    assert count(preview_pixels(alpha), (29, 32, 33)) < count(preview_pixels(broken), (29, 32, 33))
    photo = run('jpeg', lambda w: click(w, 7))
    green = sum(n for n, rgb in preview_pixels(photo).getcolors(photo.width * photo.height) if abs(rgb[0] - 70) < 4 and abs(rgb[1] - 210) < 4 and abs(rgb[2] - 90) < 4)
    assert green > 10000, 'JPEG photo preview'
    navigation = run('navigation', lambda w: (click(w, 1), backspace()))
    assert count(preview_pixels(navigation), (29, 32, 33)) == 0
    assert not (temp / 'config/sms/settings').exists(), 'preview must not persist extra state'
    print('PASS: wide/tall images, JPEG, rapid selection, errors, non-image hide, size limits, alpha, navigation, no settings writes')
