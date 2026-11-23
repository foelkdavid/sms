#!/usr/bin/env python3
"""Settings/openers integration checks; needs X11 + XTest. All config is temporary."""
import ctypes as c
import ctypes.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
x = c.CDLL(ctypes.util.find_library('X11'))
xt = c.CDLL(ctypes.util.find_library('Xtst'))
x.XOpenDisplay.restype = c.c_void_p
display = x.XOpenDisplay(None)
assert display, 'an X11 display is required'
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
root = x.XDefaultRootWindow(display)
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)]
x.XFree.argtypes = [c.c_void_p]
x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
x.XKeysymToKeycode.restype = c.c_uint
x.XFlush.argtypes = [c.c_void_p]
x.XWarpPointer.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_int, c.c_int]
xt.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
xt.XTestFakeButtonEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
x.XGetGeometry.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_uint), c.POINTER(c.c_uint), c.POINTER(c.c_uint), c.POINTER(c.c_uint)]


def settings_box(window):
    root_return, px, py = c.c_ulong(), c.c_int(), c.c_int()
    width, height, border, depth = c.c_uint(), c.c_uint(), c.c_uint(), c.c_uint()
    x.XGetGeometry(display, window, c.byref(root_return), c.byref(px), c.byref(py), c.byref(width), c.byref(height), c.byref(border), c.byref(depth))
    w, h = min(width.value - 80, 780), min(height.value - 80, 600)
    return (width.value - w) // 2, (height.value - h) // 2, w, h


def openers_tab(window):
    bx, by, width, height = settings_box(window)
    click(window, bx + width * 3 // 4, by + 70)


def find_window(window, pid):
    kind, fmt, count, remaining, data = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong(), c.c_void_p()
    atom = x.XInternAtom(display, b'_NET_WM_PID', True)
    x.XGetWindowProperty(display, window, atom, 0, 1, False, 0, c.byref(kind), c.byref(fmt), c.byref(count), c.byref(remaining), c.byref(data))
    try:
        if data and count.value and c.cast(data, c.POINTER(c.c_ulong))[0] == pid:
            return window
    finally:
        if data:
            x.XFree(data)
    tree_root, parent, count = c.c_ulong(), c.c_ulong(), c.c_uint()
    children = c.POINTER(c.c_ulong)()
    if not x.XQueryTree(display, window, c.byref(tree_root), c.byref(parent), c.byref(children), c.byref(count)):
        return None
    try:
        for i in range(count.value):
            result = find_window(children[i], pid)
            if result:
                return result
    finally:
        if children:
            x.XFree(children)


def key(sym, down):
    xt.XTestFakeKeyEvent(display, x.XKeysymToKeycode(display, sym), down, 0)
    x.XFlush(display)
    time.sleep(.04)


def press(sym):
    key(sym, True)
    key(sym, False)


def chord(letter):
    key(0xffe3, True)
    press(ord(letter))
    key(0xffe3, False)
    time.sleep(.12)


def click(window, px, py):
    x.XWarpPointer(display, 0, window, 0, 0, 0, 0, px, py)
    x.XFlush(display)
    time.sleep(.05)
    for down in (True, False):
        xt.XTestFakeButtonEvent(display, 1, down, 0)
        x.XFlush(display)
        time.sleep(.05)


with tempfile.TemporaryDirectory(prefix='sms-settings-') as temporary:
    base = Path(temporary)
    folder = base / 'files'
    folder.mkdir()
    filename = folder / 'a space;$(touch BAD).pdf'
    filename.touch()
    (folder / 'b.txt').touch()
    config = base / 'config/sms'
    config.mkdir(parents=True)
    log = base / 'launch.log'
    executable = base / 'test opener'
    executable.write_text('#!/usr/bin/python3\nimport os,sys\nwith open(os.environ["SMS_TEST_LOG"], "a") as f: f.write(repr(sys.argv[1:])+"\\n")\n')
    executable.chmod(0o755)
    env = dict(os.environ, XDG_CONFIG_HOME=str(config.parent), SMS_TEST_LOG=str(log))

    def run(name, action):
        process = subprocess.Popen([str(ROOT / 'build/sms'), '-d', str(folder), '--scale', '1', '--frames', '240', '--shot', f'/tmp/sms-settings-{name}.png'], env=env, stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 3
            window = None
            while not window and time.monotonic() < deadline:
                window = find_window(root, process.pid)
                time.sleep(.05)
            assert window, 'window did not appear'
            if os.environ.get('HYPRLAND_INSTANCE_SIGNATURE') and shutil.which('hyprctl'):
                subprocess.run(['hyprctl', 'dispatch', 'focuswindow', f'pid:{process.pid}'], check=True, stdout=subprocess.DEVNULL)
            x.XSetInputFocus(display, window, 1, 0)
            time.sleep(.2)
            action(window)
            assert process.wait(timeout=40) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    run('shortcuts', lambda window: chord('k'))
    assert '*.pdf | firefox-esr' in (config / 'openers').read_text()
    (config / 'openers').write_text(f'# Test first-match precedence\n*.pdf | {executable}\n* | definitely-not-a-real-executable\n')

    def activate(window):
        press(0xff54)  # parent
        press(0xff54)  # pdf
        press(0xff0d)
        time.sleep(.3)
        assert log.read_text().splitlines() == [repr([str(filename)])]
        chord('k')
        press(0xff54)
        press(0xff0d)  # modal must block list activation
        time.sleep(.2)
        assert len(log.read_text().splitlines()) == 1
        press(0xff1b)  # close settings
        press(0xff0d)
        time.sleep(.3)
        assert len(log.read_text().splitlines()) == 2
        chord('k')
        openers_tab(window)
        bx, by, width, height = settings_box(window)
        click(window, bx + 180, by + height - 34)  # Save

    run('openers', activate)
    assert f'*.pdf | {executable}' in (config / 'openers').read_text()
    assert not (ROOT / 'BAD').exists(), 'filenames must never be interpreted by a shell'
    (config / 'openers').write_text('invalid rule without separator\n')
    run('invalid', lambda window: (chord('k'), openers_tab(window)))
    assert (config / 'openers').read_text() == 'invalid rule without separator\n'
print('Settings and opener checks passed. Screenshots: /tmp/sms-settings-*.png')
