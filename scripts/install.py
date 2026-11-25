#!/usr/bin/env python3
"""Per-user installation; no settings or saved locations are touched."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def desktop_string(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace(" ", "\\s")


def exec_arg(value):
    # Exec has its own quoting layer in addition to desktop-string escaping.
    value = str(value)
    # xdg-open's generic fallback cannot parse a quoted executable, even a simple one.
    if re.fullmatch(r"[A-Za-z0-9_./-]+", value):
        return value
    value = value.replace("%", "%%")
    for char in ('\\', '"', '`', '$'):
        value = value.replace(char, '\\' + char)
    return desktop_string('"' + value + '"')


def refresh_icons(data):
    # Refresh an existing GTK icon cache (a stale one hides the new icon); never create one. Tools are optional.
    cmds = [["update-desktop-database", str(data / "applications")]]
    if (data / "icons/hicolor/icon-theme.cache").exists():
        cmds.append(["gtk-update-icon-cache", "-q", "-t", str(data / "icons/hicolor")])
    for cmd in cmds:
        try:
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            pass


def main():
    if sys.argv[1:] not in (["install"], ["uninstall"]):
        raise SystemExit("usage: install.py install|uninstall")
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    if not data.is_absolute():
        raise SystemExit("XDG_DATA_HOME must be absolute")
    binary = home / ".local/bin/sms"
    desktop = data / "applications/sms.desktop"
    icon = data / "icons/hicolor/scalable/apps/sms.svg"
    licenses = data / "sms/licenses"
    notices = ("FONT-OFL.txt", "RAYLIB-LICENSE.txt", "BMU-LICENSE.txt")
    if sys.argv[1] == "uninstall":
        for path in (binary, desktop, icon, *(licenses / name for name in notices)):
            path.unlink(missing_ok=True)
        for directory in (licenses, licenses.parent):
            try:
                directory.rmdir()
            except OSError:
                pass  # Preserve any unrelated files.
        refresh_icons(data)
        print("Uninstalled sms (settings preserved).")
        return
    binary.parent.mkdir(parents=True, exist_ok=True)
    desktop.parent.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)
    # Replace the inode so reinstalling also works while sms is running.
    with tempfile.NamedTemporaryFile(dir=binary.parent, prefix=".sms-", delete=False) as staged:
        temporary = Path(staged.name)
    try:
        shutil.copyfile(ROOT / "build/sms", temporary)
        temporary.chmod(0o755)
        temporary.replace(binary)
    finally:
        temporary.unlink(missing_ok=True)
    for name in notices:
        destination = licenses / name
        shutil.copyfile(ROOT / "licenses" / name, destination)
        destination.chmod(0o644)
    template = (ROOT / "sms.desktop").read_text()
    # No folder given (the launcher): home; a folder from xdg-open / a file manager: that folder.
    desktop.write_text(template.replace("@EXEC@", exec_arg(binary) + " --fallback-home %f"))
    desktop.chmod(0o644)
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "assets/sms.svg", icon)
    icon.chmod(0o644)
    refresh_icons(data)
    print(f"Installed {binary}, {desktop} and {icon}")
    print("Ensure ~/.local/bin is on PATH to run sms from a terminal.")


if __name__ == "__main__":
    main()
