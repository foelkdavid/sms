# sms — show my stuff

A minimal file explorer built with C3 and [bmu](bmu/).

```sh
c3c build
./build/sms                      # browse the directory you run it from
./build/sms --dir ~/Downloads
./build/sms -d /tmp
```

Click a folder to enter it (opens on mouse release, so you can drag it instead). Files are listed and selectable; select a supported image to preview it. Launching files and file operations are intentionally not implemented yet. Hidden files are hidden by default; Ctrl+H toggles them using the cached listing (no filesystem rescan). Folders sort first, then names case-insensitively.

- **../ row / Up / Backspace:** parent folder (`../` appears first in the list, except at filesystem root)
- **Home button:** home folder
- **Ctrl+L:** edit the path; Enter navigates (relative paths use the displayed folder)
- **Ctrl+H:** show/hide hidden files (hidden on first launch; remembered thereafter)
- **Ctrl+S:** show/hide the locations sidebar (visible on first launch; remembered thereafter)
- **Sidebar +:** save the current folder as a location; or drag a folder from the file list onto the sidebar. A small movement threshold distinguishes dragging from a click. Escape cancels a drag; dropping elsewhere does nothing. This only saves a shortcut—it never moves the folder.
- Folders dropped onto the visible sidebar from another file manager are also accepted (where supported by the window system). Files are ignored; duplicate locations are not added.
- Click a saved location to browse it, or its × to remove it. Home and File system are built in. The sidebar is 184 logical px wide with left-aligned icons and labels.
- File rows start at 54 logical px, with 32 px icons and 20 px filenames. LOCATIONS uses 15 px text; the item count uses 16 px.
- **Refresh / F5:** reload the listing
- **Ctrl +/−:** file-list zoom, in 10% steps (50–250%); **Ctrl+0** resets it to 100%
- **Ctrl+Shift +/−:** whole-UI zoom, in 25% steps (75–300%); **Ctrl+Shift+0** resets it to the monitor default
- Both zoom levels are remembered. Plus/minus keys follow the keyboard layout; keypad +/− also work.

## Install / uninstall (Linux)

C3 0.8.x has no literal `c3c install` or `c3c uninstall` command; use these project targets (requires Python 3):

```sh
c3c build install --trust=full
c3c build uninstall --trust=full
```

Install builds sms first, then copies it to `~/.local/bin/sms`, generates a desktop launcher from `sms.desktop` under `$XDG_DATA_HOME/applications` (default `~/.local/share/applications`), and copies the license notices to `$XDG_DATA_HOME/sms/licenses`. The launcher opens your home folder and does not depend on the checkout. Add `~/.local/bin` to `PATH` for terminal use. No sudo is needed; `--trust=full` allows C3 to run the installation script.

Uninstall removes those installed files, without building the app or deleting settings and saved locations.

## Image preview

Select a **PNG, JPEG, BMP, or GIF** to show a right-hand preview, fitted without stretching or enlarging beyond
its cached pixel resolution. The panel shows the filename and original dimensions. GIF previews use the first
frame; EXIF rotation is not applied. Selecting a non-image/folder, navigating, refreshing, or toggling hidden files
clears the preview. There are no thumbnails or persisted preview state.

Reading, decoding, and downsampling happen on a lazy background worker in bmu; rapid selections replace pending
work and discard stale results. Only the current preview texture is retained. GPU upload happens once on the UI
thread, not every frame. Files over **32 MiB**, images over **32 megapixels**, or edges over **16384 px** show a
limit message; previews are downsampled to a maximum **1600 px** edge. Decoding still temporarily needs the full
source bitmap and workspace (the preview-size limit is not a total-memory cap). Closing waits for any in-flight
read/decode; slow/network filesystem reads cannot be interrupted here. SVG/WebP previews are not included.

## Remembered settings

Hidden-file visibility, sidebar visibility, content and UI scales, and up to 32 saved locations are saved on normal exit to `$XDG_CONFIG_HOME/sms/settings` (default `~/.config/sms/settings`). The current directory is not remembered: startup still uses the working directory or `--dir` / `-d`. No settings writes happen per frame. Simultaneous instances use last-exit-wins settings.

## Font and third-party licensing

The embedded CodeNewRoman Nerd Font Propo is supplied by bmu under SIL OFL 1.1. Embedding it in an app, including a commercial app, is permitted. Distribute the copyright notice and complete license with each copy: [licenses/FONT-OFL.txt](licenses/FONT-OFL.txt). Keep the font under OFL; do not sell it on its own. Modified fonts must respect any reserved font names; do not imply author endorsement. The OFL does not require the application code to use OFL.

This describes the license bundled with the font; it is not an independent audit of the patched glyphs' upstream provenance. Preserve upstream notices when replacing/updating the font. raylib's notice is in [licenses/RAYLIB-LICENSE.txt](licenses/RAYLIB-LICENSE.txt). Ship the `licenses/` directory with binary releases (embedding the font alone does not make these notices easily accessible). bmu's application/library code currently has no chosen license, separate from the font and raylib licenses; choose/confirm code licensing before public distribution.

## Performance

Performance is a permanent project priority; see [AGENTS.md](AGENTS.md). Optimized build (`O2`), cached directory entries, no filesystem work in the frame loop, and only visible rows are processed/drawn. Shared sorting improvements live in bmu, not an app-local fork.

Current boundaries: directory reads are synchronous on navigation, with a visible limit warning at 16,384 entries. Slow/network folders can still block navigation. Rendering currently uses bmu's standard 60 FPS loop; it is not event-driven. No startup or navigation latency guarantees have been measured yet.

## Checks

`python3 tests/install.py` builds and checks installation, the generated desktop launcher, bundled license notices, and repeatable uninstall. It uses temporary home/config/data directories and verifies that uninstall preserves settings and unrelated files (requires Python 3 and C3; no display needed).

`python3 tests/preview.py` checks image selection, aspect ratios, transparency, stale-result replacement, errors,
limits, and clearing on navigation/non-image selection (requires visible X11/XTest and Pillow; Hyprland uses
`hyprctl` for pointer placement). Tests locate their own process window, not an already-running sms window.

`python3 tests/zoom.py` checks zoom shortcuts, independent scales, persistence, resets, and malformed settings under a temporary `XDG_CONFIG_HOME` (requires a visible X11 display and XTest).

```sh
./build/sms --help
./build/sms --shot /tmp/sms.png
./build/sms -d ~ --shot /tmp/sms-home.png
./build/sms --dir /tmp --shot /tmp/sms-tmp.png
```

bmu is pinned as a git submodule. Clone with `--recurse-submodules` or run `git submodule update --init`.
