#!/usr/bin/env python3
"""X11 integration check. Run c3c build, then python3 tests/zoom.py.
Uses only temporary settings and Python's standard library + X11/XTest.
"""
import ctypes as c
import ctypes.util
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
x = c.CDLL(ctypes.util.find_library('X11'))
xt = c.CDLL(ctypes.util.find_library('Xtst'))
x.XOpenDisplay.restype = c.c_void_p
display = x.XOpenDisplay(None)
assert display, 'a visible X11 display is required'
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
root = x.XDefaultRootWindow(display)
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_char_p)]
x.XFree.argtypes = [c.c_void_p]
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)]
x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
x.XKeysymToKeycode.restype = c.c_uint
x.XFlush.argtypes = [c.c_void_p]
xt.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]


def find_window(window, pid):
    name = c.c_char_p()
    x.XFetchName(display, window, c.byref(name))
    match = name.value == b'sms'
    if name:
        x.XFree(name)
    if match:
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
    return None


def key(sym, down):
    code = x.XKeysymToKeycode(display, sym)
    assert code, f'no keycode for keysym {sym:x}'
    xt.XTestFakeKeyEvent(display, code, down, 0)
    x.XFlush(display)
    time.sleep(.05)


def chord(sym, shift=False):
    key(0xffe3, True)  # Control_L
    if shift:
        key(0xffe1, True)  # Shift_L
    key(sym, True)
    key(sym, False)
    if shift:
        key(0xffe1, False)
    key(0xffe3, False)
    time.sleep(.1)


with tempfile.TemporaryDirectory(prefix='sms-zoom-test-') as temp:
    temp = Path(temp)
    folder = temp / 'files'
    folder.mkdir()
    (folder / 'sample.txt').touch()
    (folder / 'folder').mkdir()
    config = temp / 'config'
    settings = config / 'sms/settings'
    env = dict(os.environ, XDG_CONFIG_HOME=str(config))

    def run(name, action=lambda: None):
        shot = '/tmp/sms-zoom-' + name + '.png'
        process = subprocess.Popen([str(ROOT / 'build/sms'), '-d', str(folder), '--frames', '180', '--shot', shot], env=env)
        try:
            deadline = time.monotonic() + 2
            window = None
            while time.monotonic() < deadline and not window:
                time.sleep(.05)
                window = find_window(root, process.pid)
            assert window, 'sms window did not appear'
            time.sleep(.4)
            if os.environ.get('HYPRLAND_INSTANCE_SIGNATURE') and shutil.which('hyprctl'):
                subprocess.run(['hyprctl', 'dispatch', 'focuswindow', f'pid:{process.pid}'], check=True, stdout=subprocess.DEVNULL)
            x.XSetInputFocus(display, window, 1, 0)
            x.XFlush(display)
            time.sleep(.6)
            action()
            assert process.wait(timeout=15) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

    def values():
        return dict(line.split('=', 1) for line in settings.read_text().splitlines())

    run('default')
    assert not settings.exists(), 'no settings writes without a user change'
    run('content', lambda: (chord(ord('+')), chord(ord('+'))))
    assert values()['content_scale'] == '120', values()
    assert values()['ui_scale'] == '0', 'content zoom must not affect toolbar/sidebar'
    run('ui', lambda: chord(ord('+'), shift=True))
    assert values()['content_scale'] == '120', 'UI zoom must not double-apply content zoom'
    assert values()['ui_scale'] == '125'
    run('restored-minus', lambda: (chord(0xffad), chord(ord('-'), shift=True)))  # KP_Subtract
    assert values()['content_scale'] == '110', 'content zoom restored before keypad minus'
    assert values()['ui_scale'] == '100', 'UI zoom restored before shift-minus'
    run('reset', lambda: (chord(ord('0')), chord(ord('0'), shift=True)))
    assert values()['content_scale'] == '100'
    # UI reset uses the monitor default; it must remain a valid saved scale.
    assert 75 <= int(values()['ui_scale']) <= 300
    settings.write_text('content_scale=999999999999999999999\nui_scale=nan\nhidden=0\nsidebar=1\n')
    run('invalid-settings', lambda: chord(ord('h')))
    assert values()['content_scale'] == '100'
    assert values()['ui_scale'] == '0'
    print('PASS: independent content/UI shortcuts, keypad, persistence, resets, invalid settings, no default writes')
