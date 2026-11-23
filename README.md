# sms — show my stuff

A minimal file explorer built with C3 and [bmu](bmu/).

```sh
c3c build
./build/sms                      # browse the directory you run it from
./build/sms --dir ~/Downloads
./build/sms -d /tmp
```

Single-click to select; double-click a folder to enter it. The `../` parent row goes up with a single click. Folder dragging still saves locations without opening the folder. Files are listed and selectable; select a supported image to preview it. Double-click a file or select it and press Enter to launch its configured opener. File operations are not implemented. Hidden files are hidden by default; Ctrl+H toggles them using the cached listing (no filesystem rescan). Folders sort first, then names case-insensitively.

- **../ row / Up / Backspace:** parent folder (`../` appears first in the list, except at filesystem root)
- **Home button:** home folder
- **Up/Down:** move the selection and scroll it into view (including the `../` parent row); hold to repeat
- **Enter:** open the selected folder or launch the selected file’s configured opener; **Backspace:** go to the parent folder
- **Ctrl+L:** edit the path; Enter navigates (relative paths use the displayed folder)
- **Ctrl+F:** search file and folder names in the current directory (case-insensitive substring, not recursive). Results update as you type using the cached listing and respect hidden-file visibility. Enter leaves the filter applied; Escape or the search bar’s × clears it. Navigation clears the search.
- **Ctrl+H:** show/hide hidden files (hidden on first launch; remembered thereafter)
- **Ctrl+S:** show/hide the locations sidebar (visible on first launch; remembered thereafter)
- **Ctrl+K:** open/close Settings, with **Keyboard shortcuts** and **File openers** tabs; Escape closes Settings
- **Sidebar +:** save the current folder as a location; or drag a folder from the file list onto the sidebar. A small movement threshold distinguishes dragging from a click. Escape cancels a drag; dropping elsewhere does nothing. This only saves a shortcut—it never moves the folder.
- Folders dropped onto the visible sidebar from another file manager are also accepted (where supported by the window system). Files are ignored; duplicate locations are not added.
- Click a saved location to browse it, or its × to remove it. Home and File system are built in. The sidebar is 184 logical px wide with left-aligned icons and labels.
- File rows start at 54 logical px, with 32 px icons and 20 px filenames. LOCATIONS uses 15 px text; the item count uses 16 px.
- **Refresh / F5:** reload the listing
- **Ctrl +/−:** file-list zoom, in 10% steps (50–250%); **Ctrl+0** resets it to 100%
- **Ctrl+Shift +/−:** whole-UI zoom, in 25% steps (75–300%); **Ctrl+Shift+0** resets it to the monitor default
- Both zoom levels are remembered. Plus/minus keys follow the keyboard layout; keypad +/− also work.

## File openers

Press **Ctrl+K**, then choose **File openers** to add, edit, or remove rules. Press **Save** to persist them. Edits apply in the current session; unsaved edits are lost on exit. Single-click still selects files and previews supported images; double-click or Enter launches the matching opener.

Rules are stored in `$XDG_CONFIG_HOME/sms/openers`, falling back to `~/.config/sms/openers`. A missing file is created with this default:

```text
*.pdf | firefox-esr
```

Use comma-separated patterns to share an opener across file types:

```text
*.png,*.jpg,*.jpeg | your-image-viewer
```

The editor places patterns and their executable side by side on one row. Spaces around commas are ignored; empty alternatives (such as `*.png,`) are invalid. Commas are always separators, not literal filename characters.

You can also edit this text file directly and restart sms. Blank lines and `#` comment lines are ignored. Patterns are case-sensitive filename globs (`*`, `?`, and bracket expressions), not paths; any pattern in a rule can match, and the first matching rule wins. An empty file disables all openers.

The right-hand side is **one executable name or absolute executable path**, not a shell command. It can contain spaces if they are part of the executable path. sms searches `PATH` for executable names and passes the selected file’s absolute path as a single argument. Shell syntax, extra arguments, and placeholders are not supported; use a wrapper script if needed. Only configure executables you trust.

Limits: 16 rules, 255 bytes per comma-separated pattern list, 1023 bytes per executable, config file under 22000 bytes, and at most 16 concurrent opener processes. Invalid/oversized configs disable all rules and show an error in Settings, without modifying the file. Missing matches and launch failures show a notification. Launches do not wait for the opener to finish.

## Install / uninstall (Linux)

sms needs a **Wayland** session (it has no X11/XWayland support; the last X11 build is the `xwayland` branch).

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

sms is Wayland-only (no X11/XWayland). The former X11/XTest UI tests (`preview.py`, `settings.py`, `zoom.py`) can't
drive a Wayland window and were removed; they remain on the frozen `xwayland` branch. Wayland UI automation (via the
compositor's virtual pointer/keyboard protocols) is not set up yet: check UI changes with `--shot` and by hand.

Headless opener checks (use a temporary directory):

```sh
c3c compile tests/openers.c3 src/openers.c3 src/prefs.c3 --libdir bmu/lib --lib bmu --lib raylib6 -o /tmp/sms-openers-check
tmp=$(mktemp -d)
XDG_CONFIG_HOME="$tmp" /tmp/sms-openers-check "$tmp/sms"
rm -rf "$tmp"
```

```sh
./build/sms --help
./build/sms --shot /tmp/sms.png
./build/sms -d ~ --shot /tmp/sms-home.png
./build/sms --dir /tmp --shot /tmp/sms-tmp.png
```

bmu is pinned as a git submodule. Clone with `--recurse-submodules` or run `git submodule update --init`.
