#!/usr/bin/env python3
"""Per-user installation; no settings or saved locations are touched."""
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent


def desktop_string(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace(" ", "\\s")


def exec_arg(value):
    # Exec has its own quoting layer in addition to desktop-string escaping.
    value = str(value).replace("%", "%%")
    for char in ('\\', '"', '`', '$'):
        value = value.replace(char, '\\' + char)
    return desktop_string('"' + value + '"')


def main():
    if sys.argv[1:] not in (["install"], ["uninstall"]):
        raise SystemExit("usage: install.py install|uninstall")
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    if not data.is_absolute():
        raise SystemExit("XDG_DATA_HOME must be absolute")
    binary = home / ".local/bin/sms"
    desktop = data / "applications/sms.desktop"
    licenses = data / "sms/licenses"
    notices = ("FONT-OFL.txt", "RAYLIB-LICENSE.txt")
    if sys.argv[1] == "uninstall":
        for path in (binary, desktop, *(licenses / name for name in notices)):
            path.unlink(missing_ok=True)
        for directory in (licenses, licenses.parent):
            try:
                directory.rmdir()
            except OSError:
                pass  # Preserve any unrelated files.
        print("Uninstalled sms (settings preserved).")
        return
    binary.parent.mkdir(parents=True, exist_ok=True)
    desktop.parent.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "build/sms", binary)
    binary.chmod(0o755)
    for name in notices:
        destination = licenses / name
        shutil.copyfile(ROOT / "licenses" / name, destination)
        destination.chmod(0o644)
    template = (ROOT / "sms.desktop").read_text()
    desktop.write_text(template.replace("@EXEC@", exec_arg(binary) + " --dir " + exec_arg(home)))
    desktop.chmod(0o644)
    print(f"Installed {binary} and {desktop}")
    print("Ensure ~/.local/bin is on PATH to run sms from a terminal.")


if __name__ == "__main__":
    main()
