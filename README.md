# sms — show my stuff

A minimal file explorer built with C3 and [bmu](bmu/).

```sh
c3c build
./build/sms                      # browse the directory you run it from
./build/sms --dir ~/Downloads
./build/sms -d /tmp
```

Click a folder to enter it (opens on mouse release, so you can drag it instead). Files are listed and selectable; launching files and file operations are intentionally not implemented yet. Hidden files are hidden by default; Ctrl+H toggles them using the cached listing (no filesystem rescan). Folders sort first, then names case-insensitively.

- **Up / Backspace:** parent folder
- **Home button:** home folder
- **Ctrl+L:** edit the path; Enter navigates (relative paths use the displayed folder)
- **Ctrl+H:** show/hide hidden files (hidden on first launch; remembered thereafter)
- **Ctrl+S:** show/hide the locations sidebar (visible on first launch; remembered thereafter)
- **Sidebar +:** save the current folder as a location; or drag a folder from the file list onto the sidebar. A small movement threshold distinguishes dragging from a click. Escape cancels a drag; dropping elsewhere does nothing. This only saves a shortcut—it never moves the folder.
- Folders dropped onto the visible sidebar from another file manager are also accepted (where supported by the window system). Files are ignored; duplicate locations are not added.
- Click a saved location to browse it, or its × to remove it. Home and File system are built in. The sidebar is 184 logical px wide with left-aligned icons and labels.
- Larger list rows (42 logical px), 25 px icons, and 17 px filenames make folders easier to see; Ctrl +/-/0 still scales the whole UI.
- **Refresh / F5:** reload the listing
- **Ctrl +/-/0:** UI zoom

The desktop launcher `sms.desktop` opens `~`. It uses absolute paths for this checkout; update `Exec` and `Path` if moving the project. Install with:

```sh
install -Dm644 sms.desktop ~/.local/share/applications/sms.desktop
```

## Remembered settings

Hidden-file visibility, sidebar visibility, and up to 32 saved locations are saved on normal exit to `$XDG_CONFIG_HOME/sms/settings` (default `~/.config/sms/settings`). The current directory is not remembered: startup still uses the working directory or `--dir` / `-d`. No settings writes happen per frame. Simultaneous instances use last-exit-wins settings.

## Font and third-party licensing

The embedded CodeNewRoman Nerd Font Propo is supplied by bmu under SIL OFL 1.1. Embedding it in an app, including a commercial app, is permitted. Distribute the copyright notice and complete license with each copy: [licenses/FONT-OFL.txt](licenses/FONT-OFL.txt). Keep the font under OFL; do not sell it on its own. Modified fonts must respect any reserved font names; do not imply author endorsement. The OFL does not require the application code to use OFL.

This describes the license bundled with the font; it is not an independent audit of the patched glyphs' upstream provenance. Preserve upstream notices when replacing/updating the font. raylib's notice is in [licenses/RAYLIB-LICENSE.txt](licenses/RAYLIB-LICENSE.txt). Ship the `licenses/` directory with binary releases (embedding the font alone does not make these notices easily accessible). bmu's application/library code currently has no chosen license, separate from the font and raylib licenses; choose/confirm code licensing before public distribution.

## Performance

Performance is a permanent project priority; see [AGENTS.md](AGENTS.md). Optimized build (`O2`), cached directory entries, no filesystem work in the frame loop, and only visible rows are processed/drawn. Shared sorting improvements live in bmu, not an app-local fork.

Current boundaries: directory reads are synchronous on navigation, with a visible limit warning at 16,384 entries. Slow/network folders can still block navigation. Rendering currently uses bmu's standard 60 FPS loop; it is not event-driven. No startup or navigation latency guarantees have been measured yet.

## Checks

```sh
./build/sms --help
./build/sms --shot /tmp/sms.png
./build/sms -d ~ --shot /tmp/sms-home.png
./build/sms --dir /tmp --shot /tmp/sms-tmp.png
```

bmu is pinned as a git submodule. Clone with `--recurse-submodules` or run `git submodule update --init`.
