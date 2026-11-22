# sms — show my stuff

A minimal file explorer built with C3 and [bmu](bmu/).

```sh
c3c build
./build/sms                      # browse the directory you run it from
./build/sms --dir ~/Downloads
./build/sms -d /tmp
```

Click a folder to enter it. Files are listed and selectable; launching files and file operations are intentionally not implemented yet. Hidden files are shown. Folders sort first, then names case-insensitively.

- **Up / Backspace:** parent folder
- **Home button:** home folder
- **Ctrl+L:** edit the path; Enter navigates (relative paths use the displayed folder)
- **Refresh / F5:** reload the listing
- **Ctrl +/-/0:** UI zoom

The desktop launcher `sms.desktop` opens `~`. It uses absolute paths for this checkout; update `Exec` and `Path` if moving the project. Install with:

```sh
install -Dm644 sms.desktop ~/.local/share/applications/sms.desktop
```

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
