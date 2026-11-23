module sms;
import std::math, std::core::string, std::io, libc;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::fileop, bmu::find;
import sms::prefs, sms::preview, sms::settings, sms::openers, sms::ops, sms::complete;

const int ID_PATH = 1;
const int ID_SEARCH = 2;
const int MAX_ENTRIES = 16384;
const float ROW = 54;
const float FILE_ICON = 32;
const float FILE_TEXT = 20;
const float SIDE_W = 184;
const float SIDE_ROW = 40;
char[4096] directory;
char[4096] path_edit;
char[256] search;
bool searching;
// Ctrl+Shift+F: recursive search results replace the list (bmu::find worker; restarted 150 ms after typing).
bool deep;
find::Finder finder;
double deep_due; // 0 = no restart pending
int deep_sel = -1;
float deep_scroll;
int deep_click = -1;
double deep_click_time;
int deep_shown = -1; // results count / state the status text was built for
bool deep_shown_busy;
bool deep_pick; // Enter/Tab in the search box: select the first result as soon as one exists
sys::Entry[MAX_ENTRIES] entries;
int entry_count;
int[MAX_ENTRIES] visible;
int visible_count;
int selected = -1; // Cursor: visible entry index; -1 = none, -2 = parent row.
bool[MAX_ENTRIES] marked; // Multi-selection by visible index.
int marked_count;
int anchor = -1; // Shift range origin (visible index).
int collapse_row = -1; // Plain press on a marked row: collapse to it on release unless dragged.
int drag_dirs; // Marked folders carried by the current drag (saved as locations when dropped on the sidebar).
char[4096] drop_target; // Folder under the mouse that accepts the current drag (empty = none); reset every frame.
bool band_pending; // Press on empty space / a row's blank area: a selection box starts once the mouse moves.
bool banding;
bool band_additive; // Ctrl held at start: the box adds to band_base instead of replacing.
float band_x0;
float band_y0; // Content coordinates (list top + scroll), so the box survives scrolling.
int band_lo;
int band_hi = -1;
bool[MAX_ENTRIES] band_base;
bool[MAX_ENTRIES] cut_entry; // By entry index; dimmed while their cut is on the clipboard.
bool any_cut;
char[4096] trash_files; // $XDG_DATA_HOME/Trash/files, resolved once at startup.
bool drop_trash; // The current drag is over the sidebar's Trash row; reset every frame.
Rect path_field; // the path bar, for drawing its completions on top of everything
// What the pointer is over this frame, for drops from other apps (set while drawing; no copies).
String hover_place; // sidebar place path (stable storage) or ""
bool hover_place_trash;
int hover_dir_entry = -1; // folder row
bool hover_parent_row;
Rect list_rect;
int origin_entry = -1; // Entry whose trash origin is in origin_tip (one cached record, read on hover change only).
char[4200] origin_tip;
// Bottom bar: details of the selection, rebuilt only when the selection or listing changes.
char[256] info_name;
char[640] info_detail;
float info_name_w;
float status_w;
int info_selected = -3;
int info_marked = -1;
int info_gen = -1;
int list_gen; // bumped by refilter(): the listing (and entry indices) changed
// Combined size of a multi-selection: background COUNT, started once the selection rests for 0.25 s.
fileop::Job size_job;
double size_due; // 0 = nothing pending
char[160] info_counts; // "2 folders, 3 files"
char[64] info_sizepart; // "4.2 MB", "counting…", "S for size"
char[64] info_when;
char[512] info_suffix; // " · deleted from …" in the trash
char[4096] info_single_path;
bool info_single_dir;
bool info_deep;
int info_dirs;
int info_files;
bool size_all; // S pressed: folders are included in the size
bool size_here; // S with nothing selected: sizing the shown folder (counted by its entries)
struct TypeName { String ext; String name; }
TypeName[*] type_names = {
	{ "md", "Markdown" }, { "markdown", "Markdown" }, { "txt", "Text" }, { "log", "Log file" }, { "csv", "CSV table" },
	{ "pdf", "PDF document" }, { "epub", "EPUB book" }, { "odt", "OpenDocument text" }, { "doc", "Word document" },
	{ "docx", "Word document" }, { "xls", "Excel spreadsheet" }, { "xlsx", "Excel spreadsheet" }, { "ods", "OpenDocument spreadsheet" },
	{ "ppt", "PowerPoint presentation" }, { "pptx", "PowerPoint presentation" }, { "odp", "OpenDocument presentation" },
	{ "png", "PNG image" }, { "jpg", "JPEG image" }, { "jpeg", "JPEG image" }, { "gif", "GIF image" }, { "webp", "WebP image" },
	{ "bmp", "Bitmap image" }, { "svg", "SVG image" }, { "ico", "Icon" }, { "tif", "TIFF image" }, { "tiff", "TIFF image" },
	{ "heic", "HEIC image" }, { "avif", "AVIF image" }, { "raw", "Raw image" }, { "psd", "Photoshop image" }, { "xcf", "GIMP image" },
	{ "mp3", "MP3 audio" }, { "flac", "FLAC audio" }, { "wav", "WAV audio" }, { "ogg", "Ogg audio" }, { "opus", "Opus audio" },
	{ "m4a", "AAC audio" }, { "aac", "AAC audio" }, { "mp4", "MP4 video" }, { "mkv", "Matroska video" }, { "webm", "WebM video" },
	{ "mov", "QuickTime video" }, { "avi", "AVI video" }, { "zip", "ZIP archive" }, { "tar", "Tar archive" }, { "gz", "Gzip archive" },
	{ "tgz", "Gzip archive" }, { "xz", "XZ archive" }, { "zst", "Zstandard archive" }, { "bz2", "Bzip2 archive" }, { "7z", "7-Zip archive" },
	{ "rar", "RAR archive" }, { "iso", "Disc image" }, { "img", "Disk image" }, { "deb", "Debian package" }, { "rpm", "RPM package" },
	{ "xbps", "XBPS package" }, { "appimage", "AppImage" }, { "exe", "Windows program" }, { "msi", "Windows installer" },
	{ "dll", "Windows library" }, { "so", "Shared library" }, { "a", "Static library" }, { "o", "Object file" },
	{ "c", "C source" }, { "h", "C header" }, { "cpp", "C++ source" }, { "cc", "C++ source" }, { "hpp", "C++ header" },
	{ "c3", "C3 source" }, { "c3i", "C3 interface" }, { "zig", "Zig source" }, { "zon", "Zig object notation" }, { "rs", "Rust source" },
	{ "go", "Go source" }, { "py", "Python script" }, { "sh", "Shell script" }, { "bash", "Shell script" }, { "zsh", "Shell script" },
	{ "fish", "Fish script" }, { "lua", "Lua script" }, { "rb", "Ruby script" }, { "pl", "Perl script" }, { "js", "JavaScript" },
	{ "mjs", "JavaScript" }, { "ts", "TypeScript" }, { "java", "Java source" }, { "kt", "Kotlin source" }, { "cs", "C# source" },
	{ "swift", "Swift source" }, { "html", "HTML document" }, { "htm", "HTML document" }, { "css", "CSS stylesheet" },
	{ "json", "JSON" }, { "toml", "TOML" }, { "yaml", "YAML" }, { "yml", "YAML" }, { "xml", "XML" }, { "ini", "INI settings" },
	{ "conf", "Configuration" }, { "cfg", "Configuration" }, { "desktop", "Desktop entry" }, { "service", "Service unit" },
	{ "patch", "Patch" }, { "diff", "Diff" }, { "sql", "SQL" }, { "db", "Database" }, { "sqlite", "SQLite database" },
	{ "ttf", "TrueType font" }, { "otf", "OpenType font" }, { "woff2", "Web font" }, { "torrent", "Torrent" },
	{ "key", "Key" }, { "pem", "Certificate" }, { "crt", "Certificate" }, { "gpg", "GPG file" }, { "asc", "GPG signature" }
};

<* Human type name from the extension (case-insensitive); unknown -> "EXT file". Only on selection change. *>
fn String type_name(String name, bool exec) // temp result: caller is pooled
{
	sz? dot = name.rindex_of_char('.');
	if (catch dot) return exec ? "Program" : "File";
	if (dot == 0 || (usz)dot + 1 >= name.len) return exec ? "Program" : "File";
	String ext = name[(usz)dot + 1..];
	foreach (t : type_names) if (txt::ieq(t.ext, ext)) return t.name;
	if (ext.len > 8) return exec ? "Program" : "File";
	char[16] up;
	foreach (i, c : ext) up[i] = c >= 'a' && c <= 'z' ? c - 32 : c;
	return string::tformat("%s file", (String)up[:ext.len]);
}
int pressed_row = -1;
int last_click_row = -1;
double last_click_time;
float scroll;
char[128] status;
float sidebar_scroll;
int pressed_entry = -1;
bool dragging;
rl::RLVector2 press_at;
char[4096] drag_path;

fn void mark(int vi, bool on)
{
	if (marked[vi] == on) return;
	marked[vi] = on;
	marked_count += on ? 1 : -1;
}

fn void clear_marks()
{
	if (!marked_count) return;
	for (int i = 0; i < visible_count && marked_count; i++) mark(i, false);
}

fn void mark_range(int a, int b)
{
	for (int i = math::min(a, b); i <= math::max(a, b); i++) mark(i, true);
}

// Make vi the only selected entry and the range anchor.
fn void select_only(int vi)
{
	clear_marks();
	if (vi >= 0) mark(vi, true);
	anchor = vi;
	select_entry(vi);
}

fn int main(String[] args)
{
	// Root helper for "Retry as administrator": nothing else of sms runs as root.
	if (fileop::is_helper(args)) return fileop::helper_main(args);
	String start = ".";
	for (usz i = 1; i < args.len; i++)
	{
		switch (args[i])
		{
			case "--dir": case "-d":
				if (++i >= args.len) { io::eprintfn("sms: --dir / -d needs a folder"); return 2; }
				start = args[i];
			case "--shot": case "--frames": case "--scale":
				if (++i >= args.len) { io::eprintfn("sms: missing option value"); return 2; }
			case "--help": case "-h":
				io::printn("Usage: sms [--dir PATH | -d PATH]\nDefaults to the working directory. Double-click or press Enter to open selected folders/files. Ctrl+K configures file openers.\nClick selects; Ctrl+click toggles; Shift+click / Shift+Up/Down select a range; drag on empty space draws a selection box; Ctrl+A selects all; Escape or a click on empty space clears.\nCtrl+C / Ctrl+X / Ctrl+V: copy / cut / paste (with progress and cancel); Delete: trash (Shift+Delete: permanent); drag onto a folder moves (Ctrl copies).\nCtrl+L: edit path; Ctrl+F: search current folder (Escape clears); Ctrl+Shift+F: search all subfolders; S: size selected folders; Ctrl+H: toggle hidden files; Ctrl+S: toggle sidebar; Ctrl+K: settings; Backspace or -: parent; F5: refresh.\nCtrl +/-/0: content zoom; Ctrl+Shift +/-/0: UI zoom (both remembered).");
				return 0;
			default:
				io::eprintfn("sms: unknown option: %s", args[i]); return 2;
		}
	}
	prefs::load();
	resolve_trash();
	openers::load();
	defer { if (!prefs::save()) io::eprintfn("sms: could not save settings"); }
	if (!navigate(start)) { io::eprintfn("sms: cannot read folder: %s", start); return 1; }
	ui::open("sms", 900, 640, 480, 320, (float)prefs::ui_percent / 100);
	ui::zoom_shift_only = true;
	defer ui::close();
	defer preview::close();
	defer ops::close();
	defer size_job.close();
	defer finder.close();
	ui::app_args(args);
	while (ui::running()) frame();
	return 0;
}

// Filesystem work happens only on navigation / explicit refresh, never each frame.
fn bool navigate(String path) => @pool()
{
	String p = path;
	if (p == "~") { p = sys::home(); }
	else if (p.starts_with("~/")) { p = txt::join(sys::home(), p[2..]); }
	if (!p.starts_with("/") && !txt::empty(&directory)) p = txt::join(txt::view(&directory), p);
	char[4096] resolved;
	sys::realpath(&resolved, p);
	// Check before replacing the existing listing, so a failed navigation keeps it intact.
	void* probe = sys::c_opendir(txt::z(&resolved));
	if (!probe) return false;
	sys::c_closedir(probe);
	int n = sys::list_dir(txt::view(&resolved), &entries, true);
	if (n < 0) { entry_count = 0; return false; }
	entry_count = n;
	clear_cut();
	origin_entry = -1;
	txt::set(&directory, txt::view(&resolved));
	txt::set(&path_edit, txt::view(&directory));
	searching = false;
	stop_deep();
	txt::set(&search, "");
	refilter();
	return true;
}

// Filter only on changes against the cached listing: no disk I/O or sorting.
fn void refilter() => @pool()
{
	preview::clear();
	clear_marks();
	anchor = -1;
	collapse_row = -1;
	list_gen++;
	visible_count = 0;
	for (int i = 0; i < entry_count; i++)
	{
		if (!prefs::hidden && entries[i].name[0] == '.') continue;
		if (!txt::empty(&search) && !txt::icontains(txt::view(&entries[i].name), txt::view(&search))) continue;
		visible[visible_count++] = i;
	}
	txt::set(&status, string::tformat("%d items%s%s", visible_count,
		prefs::hidden ? " · hidden shown" : "",
		entry_count == MAX_ENTRIES ? " (display limit reached)" : ""));
	selected = -1;
	pressed_row = -1;
	last_click_row = -1;
	scroll = 0;
	pressed_entry = -1;
	dragging = false;
	band_pending = false;
	banding = false;
}

fn void clear_cut()
{
	if (!any_cut) return;
	for (int i = 0; i < entry_count; i++) cut_entry[i] = false;
	any_cut = false;
}

<* Names of the selected entries (temp array of views, valid until the next navigation). *>
fn String[] marked_names()
{
	String[] out = mem::talloc_array(String, (usz)marked_count);
	int n;
	for (int i = 0; i < visible_count && n < marked_count; i++) if (marked[i]) out[n++] = txt::view(&entries[visible[i]].name);
	return out[:n];
}

<* Re-list the current folder after a file operation, keeping search and scroll position. *>
fn void reload() => @pool()
{
	float keep = scroll;
	bool was_searching = searching;
	bool was_deep = deep;
	char[256] keep_search = search;
	if (!navigate(txt::view(&directory).tcopy())) return;
	if (was_searching)
	{
		searching = true;
		search = keep_search;
		if (was_deep) { deep = true; deep_due = ui::now; refilter_keep_search(); }
		else { refilter(); }
	}
	scroll = keep;
}

<* Mark band rows [lo, hi] (hi < lo = none); rows leaving the band return to their base state. *>
fn void band_apply(int lo, int hi)
{
	if (lo == band_lo && hi == band_hi) return;
	int a = hi >= lo ? lo : band_lo;
	int b = hi >= lo ? hi : band_hi;
	if (band_hi >= band_lo) { a = math::min(a, band_lo); b = math::max(b, band_hi); }
	for (int i = math::max(a, 0); i <= b && i < visible_count; i++)
	{
		mark(i, (i >= lo && i <= hi) || (band_additive && band_base[i]));
	}
	band_lo = lo;
	band_hi = hi;
}

fn void band_start(float x, float content_y)
{
	band_pending = true;
	banding = false;
	band_x0 = x;
	band_y0 = content_y;
	press_at = rl::get_mouse_position();
}

<* Selection box: starts after a 6 px move, auto-scrolls at the list edges, updates marks only when its row range changes. *>
fn void update_band(Rect list, float row_h, int parent_rows, float content)
{
	if (!band_pending && !banding) return;
	rl::RLVector2 mouse = rl::get_mouse_position();
	if (!rl::is_mouse_button_down(rl::RLMouseButton.LEFT) || ui::top != 0 || !rl::is_window_focused())
	{
		if (banding && band_hi >= band_lo)
		{
			int origin = math::clamp((int)(band_y0 / row_h) - parent_rows, band_lo, band_hi);
			anchor = origin;
			select_entry(origin == band_lo ? band_hi : band_lo);
		}
		band_pending = false;
		banding = false;
		return;
	}
	if (band_pending)
	{
		float dx = mouse[0] - press_at[0];
		float dy = mouse[1] - press_at[1];
		if (dx * dx + dy * dy < 36) return;
		band_pending = false;
		banding = true;
		band_additive = ui::ctrl_down();
		if (band_additive) { for (int i = 0; i < visible_count; i++) band_base[i] = marked[i]; }
		else { clear_marks(); }
		band_lo = 0;
		band_hi = -1;
		pressed_row = -1;
		last_click_row = -1;
		collapse_row = -1;
		pressed_entry = -1;
		dragging = false;
	}
	float max_scroll = math::max(0.0f, content - list.height);
	if (mouse[1] < list.y) scroll = math::max(0.0f, scroll - math::min(40.0f, (list.y - mouse[1]) * 0.5f));
	if (mouse[1] > list.y + list.height) scroll = math::min(max_scroll, scroll + math::min(40.0f, (mouse[1] - list.y - list.height) * 0.5f));
	float y1 = math::clamp(mouse[1] - list.y + scroll, 0.0f, content);
	float top = math::min(band_y0, y1);
	float bottom = math::max(band_y0, y1);
	int lo = math::max(0, (int)(top / row_h) - parent_rows);
	int hi = math::min(visible_count - 1, (int)((bottom - 0.01f) / row_h) - parent_rows);
	if (bottom - top < 1) hi = lo - 1;
	band_apply(lo, hi);
}

fn void draw_band(Rect list)
{
	if (!banding) return;
	rl::RLVector2 mouse = rl::get_mouse_position();
	float y0 = list.y + band_y0 - scroll;
	float x1 = math::clamp(mouse[0], list.x, list.x + list.width);
	float y1 = math::clamp(mouse[1], list.y, list.y + list.height);
	Rect r = { math::min(band_x0, x1), math::min(y0, y1), math::abs(x1 - band_x0), math::abs(y1 - y0) };
	ui::panel(r, { 142, 192, 124, 40 });
	ui::outline(r, ui::AQUA, 0, 1);
}

fn void select_entry(int vi) => @pool()
{
	if (selected == vi) return;
	selected = vi;
	if (vi < 0 || entries[visible[vi]].dir) { preview::clear(); }
	else { preview::select(txt::join(txt::view(&directory), txt::view(&entries[visible[vi]].name))); }
}

fn void stop_deep()
{
	finder.close();
	deep = false;
	deep_due = 0;
	deep_sel = -1;
	deep_scroll = 0;
	deep_click = -1;
	deep_shown = -1;
	deep_pick = false;
}

<* Enter / Tab in the search box: leave it and select the first row (recursive: the first result, possibly later). *>
fn void pick_first()
{
	ui::unfocus();
	if (deep)
	{
		if (deep_due > 0) deep_due = ui::now; // run a pending search now
		deep_pick = true;
		return;
	}
	if (visible_count)
	{
		select_only(0);
		scroll = 0;
	}
}

<* Enter recursive search (Ctrl+Shift+F) or switch back to filtering this folder (Ctrl+F). *>
fn void start_search(bool recursive)
{
	searching = true;
	pressed_entry = -1;
	dragging = false;
	if (recursive != deep)
	{
		bool had_deep = deep;
		stop_deep();
		deep = recursive;
		if (deep) { select_only(-1); deep_due = ui::now; }
		if (had_deep || deep) refilter_keep_search();
	}
	ui::focus_on(ID_SEARCH, &search);
}

<* The plain list shows everything while recursive search owns the query. *>
fn void refilter_keep_search()
{
	char[256] keep = search;
	if (deep) txt::set(&search, "");
	refilter();
	search = keep;
	if (deep) status_for_deep(true);
}

fn String deep_path(int i) => txt::join(txt::view(&directory), finder.rel(i));

<* Status text for recursive search; rebuilt only when the count or state changes. *>
fn void status_for_deep(bool force = false) => @pool()
{
	int n = finder.results();
	bool busy = finder.searching() || deep_due > 0;
	if (!force && n == deep_shown && busy == deep_shown_busy) return;
	deep_shown = n;
	deep_shown_busy = busy;
	String more = busy ? " · searching…" : finder.limited() ? " · limit reached" : "";
	txt::set(&status, string::tformat("%d %s in all subfolders%s", n, n == 1 ? "result" : "results", more));
	list_gen++; // re-measure the status width
}

fn void deep_select(int i) => @pool()
{
	if (deep_sel == i) return;
	deep_sel = i;
	if (i < 0 || finder.is_dir(i)) { preview::clear(); }
	else { preview::select(deep_path(i)); }
}

fn void deep_open(int i) => @pool()
{
	String path = deep_path(i);
	if (finder.is_dir(i)) { go(path); }
	else { openers::launch(path); }
}

<* Recursive results: virtualized two-line rows (name, folder), keys, click / double-click. *>
fn void draw_deep(Rect list, float row_h, float icon_size, float text_size, float cs, bool keys) => @pool()
{
	if (deep_due > 0 && ui::now >= deep_due)
	{
		deep_due = 0;
		finder.close();
		deep_sel = -1;
		deep_scroll = 0;
		if (!txt::empty(&search)) finder.start(txt::view(&directory), txt::view(&search), prefs::hidden);
	}
	status_for_deep();
	int n = finder.results();
	if (deep_pick && n > 0)
	{
		deep_pick = false;
		deep_select(0);
		deep_scroll = 0;
	}
	else if (deep_pick && deep_due == 0 && !finder.searching()) { deep_pick = false; }
	int open = -1;
	if (keys && n > 0)
	{
		int step = (int)ui::repeat(rl::RLKeyboardKey.DOWN) - (int)ui::repeat(rl::RLKeyboardKey.UP);
		if (step)
		{
			int next = deep_sel < 0 ? (step > 0 ? 0 : n - 1) : math::clamp(deep_sel + step, 0, n - 1);
			deep_select(next);
			float y = (float)next * row_h;
			if (y < deep_scroll) deep_scroll = y;
			if (y + row_h > deep_scroll + list.height) deep_scroll = y + row_h - list.height;
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.ENTER) && deep_sel >= 0) open = deep_sel;
	}
	float content = (float)n * row_h;
	deep_scroll = ui::scroll_wheel(list, deep_scroll, content);
	ui::begin_clip(list);
	int first = math::max(0, (int)(deep_scroll / row_h));
	int end = math::min(n, first + (int)(list.height / row_h) + 2);
	float small = text_size * 0.68f;
	for (int i = first; i < end; i++)
	{
		Rect row = { list.x, list.y + (float)i * row_h - deep_scroll, list.width - 10, row_h };
		bool hovered = ui::hover(row);
		if (deep_sel == i) { ui::panel(row, ui::BG2, 4); }
		else if (hovered) { ui::panel(row, ui::BG1, 4); }
		bool dir = finder.is_dir(i);
		ui::text(dir ? ui::I_FOLDER : ui::I_FILE, row.x + 12 * cs, row.y + (row_h - icon_size) / 2, icon_size, dir ? ui::YELLOW : ui::GRAY);
		float top = row.y + (row_h - text_size - small - 3 * cs) / 2;
		float tw = math::max(0.0f, row.width - 72 * cs);
		ui::text_fit(finder.name(i), row.x + 60 * cs, top, tw, text_size, ui::FG);
		String folder = finder.folder(i);
		ui::text_tail(folder.len ? folder : "(this folder)", row.x + 60 * cs, top + text_size + 3 * cs, tw, small, ui::GRAY);
		if (ui::clicked(row))
		{
			ui::unfocus();
			if (deep_click == i && ui::now - deep_click_time <= 0.4) { open = i; deep_click = -1; }
			else { deep_click = i; deep_click_time = ui::now; }
			deep_select(i);
		}
	}
	if (!n)
	{
		String msg = txt::empty(&search) ? "Type to search all subfolders" : finder.searching() || deep_due > 0 ? "Searching…" : "No matches";
		ui::text(msg, list.x + 16 * cs, list.y + 16 * cs, text_size, ui::GRAY);
	}
	ui::end_clip();
	ui::scrollbar(list, deep_scroll, content);
	if (open >= 0) deep_open(open); // after drawing: navigation closes the finder
}

fn void close_search()
{
	stop_deep();
	searching = false;
	txt::set(&search, "");
	ui::unfocus();
	refilter();
}

fn void go(String path)
{
	if (navigate(path)) { ui::unfocus(); }
	else { ui::toast("Cannot read this folder", ui::RED); }
}

fn void add_location(String path)
{
	if (!prefs::add(path)) ui::toast("Cannot add location (limit: 32; no newlines in paths)", ui::RED);
}

// App-specific location rows: icons and labels share the same left edge.
fn void sidebar_location(Rect row, String path, String name, String icon, bool trash = false, String badge = "")
{
	if (path == txt::view(&directory)) ui::panel(row, ui::BG2, 4);
	if (ui::hover(row))
	{
		hover_place = path;
		hover_place_trash = trash;
		ui::panel(row, ui::BG1, 4);
		if (dragging && path != txt::view(&directory))
		{
			// Dropping on Trash trashes (with .trashinfo); other places move/copy into the folder.
			if (trash) { drop_trash = true; }
			else { txt::set(&drop_target, path); }
			ui::outline(row, ui::AQUA, 4, 2);
		}
		else if (!dragging) { ui::tooltip(path); }
	}
	ui::text(icon, row.x + 8, row.y + 8, 23, trash ? ui::RED : ui::YELLOW);
	float badge_w = badge.len ? ui::text_w(badge, 13) + 8 : 0;
	ui::text_fit(name, row.x + 40, row.y + 12, row.width - 44 - badge_w, 16, ui::FG);
	if (badge.len) ui::text(badge, row.x + row.width - badge_w, row.y + 14, 13, ui::GRAY);
	if (ui::clicked(row))
	{
		if (trash)
		{
			ensure_trash();
			ops::size_dirty = true;
		}
		go(path);
	}
}

<* Resolved like navigate() resolves folders, so comparisons with `directory` hold behind symlinks. *>
fn void resolve_trash() => @pool()
{
	char[4096] raw;
	fileop::trash_dir(&raw);
	txt::append(&raw, "/files");
	sys::realpath(&trash_files, txt::view(&raw).tcopy());
}

<* "~/x" for paths under the home folder (temp). *>
fn String home_short(String p)
{
	String home = sys::home();
	if (home.len > 1 && p.starts_with(home) && (p.len == home.len || p[home.len] == '/')) return string::tformat("~%s", p[home.len..]);
	return p;
}

<* Bottom-bar text from its parts: multi-selection counts or a single folder, plus the size part. *>
fn void compose_detail() => @pool()
{
	String size = txt::view(&info_sizepart);
	if (info_single_dir)
	{
		txt::set(&info_detail, string::tformat("Folder · %s · modified %s%s", size, txt::view(&info_when), txt::view(&info_suffix)));
	}
	else
	{
		txt::set(&info_detail, size.len ? string::tformat("%s · %s", txt::view(&info_counts), size) : txt::view(&info_counts));
	}
}

<* One item: type, size (files), modified time from one lstat; folders get their size on S. *>
fn void describe_single(String path, String shown, int trash_entry) => @pool()
{
	txt::set(&info_name, shown);
	libc::Stat st;
	if (libc::lstat(path.zstr_tcopy(), &st) != 0) { txt::set(&info_detail, "cannot read"); return; }
	uint kind = st.st_mode & 0xF000;
	char[32] when;
	libc::Tm tm;
	Time_t mt = st.st_mtime;
	libc::localtime_r(&mt, &tm);
	libc::strftime(&when, when.len, "%Y-%m-%d %H:%M", &tm);
	txt::set(&info_when, ((ZString)&when).str_view());
	txt::set(&info_suffix, trash_entry >= 0 ? string::tformat(" · %s", trash_origin(trash_entry)) : "");
	if (kind == 0x4000)
	{
		info_single_dir = true;
		txt::set(&info_single_path, path);
		txt::set(&info_sizepart, "S for size");
		compose_detail();
		return;
	}
	String type = kind == 0xA000 ? "Link" : kind != 0x8000 ? "Special file" : type_name(txt::basename(path), (st.st_mode & 0o111) != 0);
	char[32] size;
	ops::size_text(&size, (ulong)st.st_size);
	String detail = kind == 0x8000
		? string::tformat("%s · %s · modified %s", type, txt::view(&size), txt::view(&info_when))
		: string::tformat("%s · modified %s", type, txt::view(&info_when));
	txt::set(&info_detail, string::tformat("%s%s", detail, txt::view(&info_suffix)));
}

<* Rebuild the bottom-bar details when the selection changed. Several items: counts now, file sizes in the background. *>
fn void update_info(bool trash_top) => @pool()
{
	int key = deep ? deep_sel : selected;
	if (key == info_selected && marked_count == info_marked && list_gen == info_gen && deep == info_deep) return;
	if (list_gen != info_gen) status_w = ui::text_w(txt::view(&status), 16);
	info_selected = key;
	info_marked = marked_count;
	info_gen = list_gen;
	info_deep = deep;
	info_name[0] = 0;
	info_detail[0] = 0;
	info_sizepart[0] = 0;
	info_suffix[0] = 0;
	info_single_dir = false;
	info_dirs = 0;
	info_files = 0;
	size_all = false;
	size_here = false;
	size_due = 0;
	size_job.close(); // a running count is for the old selection
	if (deep)
	{
		if (deep_sel >= 0) describe_single(deep_path(deep_sel), home_short(deep_path(deep_sel)), -1);
	}
	else if (marked_count > 1)
	{
		for (int i = 0; i < visible_count; i++) if (marked[i] && entries[visible[i]].dir) info_dirs++;
		info_files = marked_count - info_dirs;
		txt::set(&info_name, string::tformat("%d selected", marked_count));
		String d = info_dirs ? string::tformat("%d %s", info_dirs, info_dirs == 1 ? "folder" : "folders") : "";
		String f = info_files ? string::tformat("%d %s", info_files, info_files == 1 ? "file" : "files") : "";
		txt::set(&info_counts, d.len && f.len ? string::tformat("%s, %s", d, f) : d.len ? d : f);
		// Files are sized automatically (debounced); folders only on S.
		if (info_files) { txt::set(&info_sizepart, "counting…"); size_due = ui::now + 0.25; }
		else { txt::set(&info_sizepart, "S for size"); }
		compose_detail();
	}
	else
	{
		int vi = selected;
		if (marked_count == 1) { for (int i = 0; i < visible_count; i++) if (marked[i]) { vi = i; break; } }
		if (vi >= 0)
		{
			String name = txt::view(&entries[visible[vi]].name);
			describe_single(txt::join(txt::view(&directory), name), name, trash_top ? visible[vi] : -1);
		}
	}
	info_name_w = ui::text_w(txt::view(&info_name), 16);
}

<* S: size the selected folders too (recursive, background). *>
fn void size_folders() => @pool()
{
	if (!deep && marked_count == 0 && selected < 0)
	{
		size_current_folder();
		return;
	}
	if (size_all || (!info_dirs && !info_single_dir)) return;
	size_all = true;
	size_due = 0;
	size_job.close();
	bool ok;
	if (info_single_dir)
	{
		String path = txt::view(&info_single_path);
		String[1] one = { txt::basename(path) };
		ok = size_job.start(COUNT, txt::dirname(path), &one);
	}
	else
	{
		ok = size_job.start(COUNT, txt::view(&directory), marked_names());
	}
	txt::set(&info_sizepart, ok ? "counting…" : "size unavailable");
	compose_detail();
}

<* S with nothing selected: size of the shown folder, counted from its entries (works for "/", includes hidden). *>
fn void size_current_folder() => @pool()
{
	if (size_here) return;
	String dir = txt::view(&directory);
	describe_single(dir, home_short(dir), -1);
	size_here = true;
	size_all = true;
	size_job.close();
	if (!entry_count)
	{
		txt::set(&info_sizepart, "empty");
	}
	else
	{
		String[] names = mem::talloc_array(String, (usz)entry_count);
		for (int i = 0; i < entry_count; i++) names[i] = txt::view(&entries[i].name);
		txt::set(&info_sizepart, size_job.start(COUNT, dir, names) ? "counting…" : "size unavailable");
	}
	compose_detail();
	info_name_w = ui::text_w(txt::view(&info_name), 16);
}

<* Start the debounced file-size COUNT and show totals when a count ends (no per-frame I/O or formatting). *>
fn void poll_selection_size() => @pool()
{
	if (size_due > 0 && ui::now >= size_due && marked_count > 1 && !deep)
	{
		size_due = 0;
		String[] files = mem::talloc_array(String, (usz)marked_count);
		int n;
		for (int i = 0; i < visible_count && n < marked_count; i++) if (marked[i] && !entries[visible[i]].dir) files[n++] = txt::view(&entries[visible[i]].name);
		if (!n || !size_job.start(COUNT, txt::view(&directory), files[:n])) { info_sizepart[0] = 0; compose_detail(); }
	}
	fileop::Progress p;
	if (!size_job.finished(&p)) return;
	char[32] size;
	ops::size_text(&size, p.bytes_total);
	String total = p.state == FAILED ? string::tformat("at least %s", txt::view(&size)) : txt::view(&size);
	if (p.state != DONE && p.state != FAILED) { info_sizepart[0] = 0; }
	else if (info_single_dir)
	{
		char[32] items;
		// Counting a folder by name includes the folder itself; counting the shown folder by its entries does not.
		int count = size_here ? p.files_total : math::max(0, p.files_total - 1);
		ops::group_digits(&items, count);
		txt::set(&info_sizepart, string::tformat("%s, %s %s", total, txt::view(&items), count == 1 ? "item" : "items"));
	}
	else if (!size_all && info_dirs) { txt::set(&info_sizepart, string::tformat("%s in files · S adds folders", total)); }
	else { txt::set(&info_sizepart, total); }
	compose_detail();
}

<* "deleted from ~/Docs on 2026-11-23 14:02" for a trash entry; reads its .trashinfo only when the hovered entry changes. *>
fn String trash_origin(int entry) => @pool()
{
	if (entry == origin_entry) return txt::view(&origin_tip);
	origin_entry = entry;
	char[4096] path;
	char[32] date;
	if (!fileop::trash_info(txt::view(&trash_files), txt::view(&entries[entry].name), &path, &date))
	{
		txt::set(&origin_tip, "no restore information");
		return txt::view(&origin_tip);
	}
	String from = txt::dirname(txt::view(&path));
	String home = sys::home();
	if (home.len > 1 && from.starts_with(home) && (from.len == home.len || from[home.len] == '/')) from = string::tformat("~%s", from[home.len..]);
	String when = txt::view(&date);
	if (when.len > 16) when = when[:16]; // drop seconds
	txt::set(&origin_tip, when.len ? string::tformat("deleted from %s on %s", from, when) : string::tformat("deleted from %s", from));
	return txt::view(&origin_tip);
}

<* The shown folder is the trash or inside it: deleting there must be permanent, never trash-in-trash. *>
fn bool in_trash()
{
	String dir = txt::view(&directory);
	String t = txt::view(&trash_files);
	return dir.starts_with(t) && (dir.len == t.len || dir[t.len] == '/');
}

<* Create the trash folders (private, per the freedesktop spec) when they are first opened. *>
fn void ensure_trash() => @pool()
{
	String files = txt::view(&trash_files);
	String root = txt::dirname(files);
	if (sys::is_dir(files)) return;
	sys::mkdirs(txt::dirname(root));
	sys::c_mkdir(root.zstr_tcopy(), 0o700);
	sys::c_mkdir(files.zstr_tcopy(), 0o700);
	sys::c_mkdir(txt::join(root, "info").zstr_tcopy(), 0o700);
	resolve_trash();
}

fn void draw_sidebar(float h)
{
	Rect bar = { 0, 60, SIDE_W, h - 88 };
	ui::panel(bar, ui::BG_HARD);
	ui::text("LOCATIONS", 16, 76, 15, ui::GRAY);
	if (ui::icon_button({ SIDE_W - 42, 68, 30, 30 }, ui::I_PLUS, ui::FG4, "Add current folder (or drag a folder here)")) add_location(txt::view(&directory));
	sidebar_location({ 8, 104, SIDE_W - 16, 40 }, sys::home(), "Home", ui::I_HOME);
	sidebar_location({ 8, 144, SIDE_W - 16, 40 }, "/", "File system", ui::I_HDD);
	float extra = 0;
	if (prefs::trash)
	{
		sidebar_location({ 8, 184, SIDE_W - 16, 40 }, txt::view(&trash_files), "Trash", ui::I_TRASH, true, txt::view(&ops::trash_size));
		extra = 40;
	}
	ui::hline(12, 192 + extra, SIDE_W - 24);
	Rect area = { 8, 204 + extra, SIDE_W - 16, h - 240 - extra };
	float content = (float)prefs::place_count * SIDE_ROW;
	sidebar_scroll = ui::scroll_wheel(area, sidebar_scroll, content);
	ui::begin_clip(area);
	int first = math::max(0, (int)(sidebar_scroll / SIDE_ROW));
	int end = math::min(prefs::place_count, first + (int)(area.height / SIDE_ROW) + 2);
	int remove = -1;
	for (int i = first; i < end; i++)
	{
		float y = area.y + (float)i * SIDE_ROW - sidebar_scroll;
		String path = txt::view(&prefs::places[i].path);
		sidebar_location({ 8, y, SIDE_W - 48, SIDE_ROW - 2 }, path, path == "/" ? "/" : txt::basename(path), ui::I_FOLDER);
		if (ui::icon_button({ SIDE_W - 38, y, 28, SIDE_ROW - 2 }, ui::I_TIMES, ui::GRAY, "Remove saved location")) remove = i;
	}
	ui::end_clip();
	ui::scrollbar(area, sidebar_scroll, content);
	if (remove >= 0) prefs::remove(remove);
	// Folders dropped on free sidebar space are saved as locations.
	if (dragging && drag_dirs && txt::empty(&drop_target) && !drop_trash && ui::point_in(rl::get_mouse_position(), bar)) ui::outline(bar, ui::AQUA, 0, 2);
}

fn void update_drag()
{
	if (pressed_entry < 0) return;
	if (ui::top != 0 || !rl::is_window_focused() || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE))
	{
		pressed_entry = -1;
		dragging = false;
		return;
	}
	rl::RLVector2 mouse = rl::get_mouse_position();
	float dx = mouse[0] - press_at[0];
	float dy = mouse[1] - press_at[1];
	if (dx * dx + dy * dy >= 36) dragging = true;
	if (!rl::is_mouse_button_down(rl::RLMouseButton.LEFT) && !rl::is_mouse_button_released(rl::RLMouseButton.LEFT))
	{
		pressed_entry = -1;
		dragging = false;
	}
}

fn void add_marked_locations() => @pool()
{
	for (int i = 0; i < visible_count; i++)
	{
		if (!marked[i] || !entries[visible[i]].dir) continue;
		if (!prefs::add(txt::join(txt::view(&directory), txt::view(&entries[visible[i]].name))))
		{
			ui::toast("Cannot add location (limit: 32; no newlines in paths)", ui::RED);
			return;
		}
	}
}

// Enter on a multi-selection opens the selected files: one opener process per rule with all its files.
// Returns false when no files are selected (folders only).
fn bool launch_marked() => @pool()
{
	String[] files = mem::talloc_array(String, (usz)marked_count);
	int n;
	for (int i = 0; i < visible_count && n < marked_count; i++) if (marked[i] && !entries[visible[i]].dir) files[n++] = txt::view(&entries[visible[i]].name);
	if (!n) return false;
	openers::launch_many(txt::view(&directory), files[:n]);
	return true;
}

<*
 Files dropped from another app (file manager): copied into the folder under the pointer (folder row, ../,
 sidebar place) or the shown folder; onto Trash they are trashed. Handled once per drop, never per frame.
*>
fn void drop_from_app() => @pool()
{
	rl::RLFilePathList dropped = rl::load_dropped_files();
	defer rl::unload_dropped_files(dropped);
	if (ui::top != 0 || !dropped.count) return;
	String target;
	if (hover_place.len) { target = hover_place; }
	else if (hover_parent_row) { target = txt::dirname(txt::view(&directory)); }
	else if (hover_dir_entry >= 0) { target = txt::join(txt::view(&directory), txt::view(&entries[hover_dir_entry].name)); }
	else if (ui::point_in(rl::get_mouse_position(), list_rect)) { target = txt::view(&directory); }
	else { return; }
	// One operation works inside one source folder: the usual case for a file-manager drag.
	String from = txt::dirname(dropped.paths[0].str_view());
	String[] names = mem::talloc_array(String, dropped.count);
	for (uint i = 0; i < dropped.count; i++)
	{
		String path = dropped.paths[i].str_view();
		if (!path.starts_with("/") || txt::dirname(path) != from) { ui::toast("Drop items from one folder at a time", ui::RED); return; }
		names[i] = txt::basename(path);
	}
	if (hover_place_trash) { ops::remove(from, names, in_trash()); return; }
	char[4096] real;
	sys::realpath(&real, from);
	if (txt::view(&real) == target) { ui::toast("Already in this folder", ui::YELLOW); return; }
	ops::transfer(txt::view(&real), names, target, true);
}

fn void finish_drag(float h)
{
	Rect bar = { 0, 60, SIDE_W, h - 88 };
	bool over_bar = prefs::sidebar && ui::point_in(rl::get_mouse_position(), bar);
	if (pressed_entry >= 0 && rl::is_mouse_button_released(rl::RLMouseButton.LEFT))
	{
		if (dragging && ui::top == 0)
		{
			if (drop_trash) { ops::remove(txt::view(&directory), marked_names(), in_trash()); }
			else if (!txt::empty(&drop_target)) { ops::transfer(txt::view(&directory), marked_names(), txt::view(&drop_target), ui::ctrl_down()); }
			else if (over_bar && drag_dirs) { add_marked_locations(); }
		}
		pressed_entry = -1;
		dragging = false;
	}
	if (rl::is_file_dropped()) drop_from_app();
	if (dragging)
	{
		rl::RLVector2 mouse = rl::get_mouse_position();
		String hint = "";
		if (!txt::empty(&drop_target))
		{
			String target = txt::view(&drop_target);
			hint = string::tformat("%s to %s", ui::ctrl_down() ? "Copy" : "Move", target == "/" ? "/" : txt::basename(target));
		}
		else if (drop_trash) { hint = "Move to trash"; }
		else if (over_bar && drag_dirs) { hint = drag_dirs == 1 ? "Save as location" : "Save as locations"; }
		ui::panel({ mouse[0] + 14, mouse[1] + 14, 230, hint.len ? 60 : 42 }, ui::BG_HARD, 4);
		bool single_dir = marked_count <= 1 && drag_dirs == 1;
		ui::text(single_dir ? ui::I_FOLDER : ui::I_FILE, mouse[0] + 24, mouse[1] + 22, 23, single_dir ? ui::YELLOW : ui::GRAY);
		String label = marked_count > 1 ? string::tformat("%d items", marked_count) : txt::basename(txt::view(&drag_path));
		ui::text_fit(label, mouse[0] + 56, mouse[1] + 27, 174, 16, ui::FG);
		if (hint.len) ui::text_fit(hint, mouse[0] + 56, mouse[1] + 50, 174, 14, ui::AQUA);
	}
}

fn void frame() => @pool()
{
	ui::frame_begin(settings::open || ops::modal());
	ops::poll();
	if (ops::take_refresh()) reload();
	drop_target[0] = 0;
	hover_place = "";
	hover_place_trash = false;
	hover_dir_entry = -1;
	hover_parent_row = false;
	drop_trash = false;
	if (prefs::trash) ops::poll_trash_size(txt::dirname(txt::view(&trash_files)));
	if (ui::ctrl_down() && ui::letter('k') && !ops::modal())
	{
		settings::toggle();
		ui::top = settings::open ? 1 : 0;
	}
	openers::poll();
	if (ui::zoom_changed)
	{
		prefs::ui_percent = (int)math::round(ui::scale * 100);
		prefs::dirty = true;
	}
	if (ui::top == 0 && ui::focus < 0 && ui::ctrl_down() && !ui::shift_down())
	{
		int previous = prefs::content_percent;
		int percent = math::clamp(previous + ui::zoom_step() * 10, 50, 250);
		if (rl::is_key_pressed(rl::RLKeyboardKey.ZERO)) percent = 100;
		if (percent != previous)
		{
			prefs::content_percent = percent;
			prefs::dirty = true;
			scroll *= (float)percent / (float)previous;
			pressed_entry = -1;
			dragging = false;
			ui::toast(string::tformat("Content scale %d%%", percent));
		}
	}
	bool was_pressing = pressed_entry >= 0;
	update_drag();
	if (dragging || !rl::is_window_focused())
	{
		last_click_row = -1;
		pressed_row = -1;
	}
	bool list_keys = ui::top == 0 && ui::focus < 0;
	preview::poll();
	float w = ui::sw();
	float h = ui::sh();
	if (ui::top == 0)
	{
		if (searching && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) close_search();
		if (ui::ctrl_down() && ui::letter('l'))
		{
			if (searching) close_search();
			// Trailing slash: the completions show the current folder's subfolders right away.
			String here = txt::view(&directory);
			if (here != "/") { txt::set(&path_edit, here); txt::append(&path_edit, "/"); }
			ui::focus_on(ID_PATH, &path_edit);
		}
		if (ui::ctrl_down() && ui::letter('f')) start_search(ui::shift_down());
	}
	if (ui::top == 0 && ui::focus < 0)
	{
		if (ui::ctrl_down() && ui::letter('h'))
		{
			prefs::hidden = !prefs::hidden;
			prefs::dirty = true;
			if (deep) { deep_due = ui::now; refilter_keep_search(); }
			else { refilter(); }
		}
		if (ui::ctrl_down() && ui::letter('s'))
		{
			prefs::sidebar = !prefs::sidebar;
			prefs::dirty = true;
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.BACKSPACE)) go(txt::dirname(txt::view(&directory)));
		// Plain "-" (layout-aware, or keypad minus) also goes up; Ctrl+- stays content zoom.
		bool minus = rl::is_key_pressed((rl::RLKeyboardKey)ui::minus_key) || rl::is_key_pressed(rl::RLKeyboardKey.KP_SUBTRACT);
		if (minus && !ui::ctrl_down() && !ui::shift_down()) go(txt::dirname(txt::view(&directory)));
		if (rl::is_key_pressed(rl::RLKeyboardKey.F5)) go(txt::view(&directory));
		if (!ui::ctrl_down() && ui::letter('s') && !deep) size_folders();
		if (ui::ctrl_down() && ui::letter('a') && visible_count && !deep)
		{
			mark_range(0, visible_count - 1);
			if (selected < 0) { select_entry(0); }
			if (anchor < 0) anchor = selected;
		}
		if (!was_pressing && !searching && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { clear_marks(); anchor = -1; collapse_row = -1; }
		if (ui::ctrl_down() && (ui::letter('c') || ui::letter('x')) && marked_count && !deep)
		{
			bool cut = ui::letter('x');
			clear_cut();
			if (cut)
			{
				for (int i = 0; i < visible_count; i++) if (marked[i]) cut_entry[visible[i]] = true;
				any_cut = true;
			}
			ops::set_clipboard(txt::view(&directory), marked_names(), cut);
		}
		if (ui::ctrl_down() && ui::letter('v'))
		{
			if (ops::has_clip()) { ops::paste(txt::view(&directory)); }
			else { ui::toast("Nothing to paste: copy (Ctrl+C) or cut (Ctrl+X) first", ui::YELLOW); }
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.DELETE) && marked_count && !deep) ops::remove(txt::view(&directory), marked_names(), ui::shift_down() || in_trash());
	}
	ui::panel({ 0, 0, w, 60 }, ui::BG_HARD);
	if (ui::icon_button({ 12, 12, 36, 36 }, ui::I_UP, ui::FG4, "Parent folder (Backspace)")) go(txt::dirname(txt::view(&directory)));
	if (ui::icon_button({ 52, 12, 36, 36 }, ui::I_HOME, ui::FG4, "Home")) go(sys::home());
	bool submitted;
	if (searching)
	{
		// Tab, Enter or Down leave the search box for the first result.
		bool tabbed = ui::focused(ID_SEARCH) && (rl::is_key_pressed(rl::RLKeyboardKey.TAB) || rl::is_key_pressed(rl::RLKeyboardKey.DOWN));
		if (ui::input(ID_SEARCH, { 100, 12, w - 192, 36 }, &search, deep ? "Search all subfolders" : "Search this folder", &submitted, ui::I_SEARCH))
		{
			if (deep) { deep_due = ui::now + 0.15; deep_shown = -1; deep_pick = false; }
			else { refilter(); }
		}
		if (submitted || tabbed)
		{
			submitted = true; // keeps this Enter from also opening the row
			pick_first();
		}
	}
	else
	{
		// Folder completions: mouse first (a click must not reach the list below), then the field, then keys.
		path_field = { 100, 12, w - 192, 36 };
		bool editing = ui::focused(ID_PATH);
		if (editing) complete::mouse(path_field, &path_edit);
		if (editing && complete::open) ui::input_arrows_free = true;
		ui::input(ID_PATH, path_field, &path_edit, "Folder path", &submitted, ui::I_FOLDER);
		if (ui::focused(ID_PATH))
		{
			if (complete::open)
			{
				if (ui::repeat(rl::RLKeyboardKey.DOWN)) complete::move(1);
				if (ui::repeat(rl::RLKeyboardKey.UP)) complete::move(-1);
				if (rl::is_key_pressed(rl::RLKeyboardKey.TAB)) complete::tab(&path_edit);
				if (submitted && complete::sel >= 0) ui::input_replace(&path_edit, complete::suggestion(complete::sel));
			}
			if (!submitted) complete::update(txt::view(&path_edit), txt::view(&directory));
		}
		else
		{
			complete::close();
		}
		if (submitted)
		{
			complete::close();
			go(txt::view(&path_edit));
			// Arrow keys continue in the list: select ../ (or the first entry at /).
			if (txt::view(&directory) != "/") { select_only(-2); }
			else if (visible_count) { select_only(0); }
		}
	}
	if (ui::icon_button({ w - 84, 12, 32, 36 }, searching ? ui::I_TIMES : ui::I_SEARCH, ui::FG4, searching ? "Clear search (Escape)" : "Search this folder (Ctrl+F)"))
	{
		if (searching) { close_search(); }
		else { start_search(false); }
	}
	if (ui::icon_button({ w - 44, 12, 32, 36 }, ui::I_REFRESH, ui::FG4, "Refresh (F5)")) go(txt::view(&directory));
	ui::hline(0, 59, w);

	float left = 8;
	if (prefs::sidebar)
	{
		draw_sidebar(h);
		left = SIDE_W + 8;
	}
	bool show_preview = preview::active;
	float preview_w = show_preview ? math::min(360.0f, (w - left - 8) * 0.45f) : 0;
	float ops_h = ops::panel_height();
	float main_h = h - 104 - (ops_h > 0 ? ops_h + 8 : 0);
	// Trash top level: a slim bar with Restore above the list.
	bool trash_top = txt::view(&directory) == txt::view(&trash_files);
	float bar_h = trash_top ? 48.0f : 0.0f;
	float list_w = w - left - 8 - (show_preview ? preview_w + 8 : 0);
	if (trash_top)
	{
		Rect tb = { left, 68, list_w - 10, 40 };
		ui::panel(tb, ui::BG_HARD, 6);
		ui::text(ui::I_TRASH, tb.x + 12, tb.y + 10, 18, ui::RED);
		ui::text("Trash", tb.x + 40, tb.y + 11, 16, ui::FG);
		if (ui::button({ tb.x + tb.width - 148, tb.y + 4, 140, 32 }, "Restore", PRIMARY, ui::I_UNDO, marked_count > 0 && !ops::busy()))
		{
			ops::restore(txt::view(&directory), marked_names());
		}
	}
	Rect list = { left, 68 + bar_h, list_w, main_h - bar_h };
	list_rect = list;
	Rect preview_panel = { w - preview_w - 8, 68, preview_w, main_h };
	Rect ops_panel = { left, 68 + main_h + 8, w - left - 8, ops_h };
	int parent_rows = txt::view(&directory) == "/" || !txt::empty(&search) || deep ? 0 : 1;
	int row_count = visible_count + parent_rows;
	float content_scale = (float)prefs::content_percent / 100;
	float row_h = ROW * content_scale;
	float icon_size = FILE_ICON * content_scale;
	float text_size = FILE_TEXT * content_scale;
	float content = (float)row_count * row_h;
	int enter = -1;
	bool go_up;
	bool multi_enter;
	bool ctrl = ui::ctrl_down();
	bool shift = ui::shift_down();
	if (deep)
	{
		draw_deep(list, row_h, icon_size, text_size, content_scale, list_keys && !submitted);
	}
	else
	{
		if (list_keys && ui::focus < 0 && !submitted && !ui::ctrl_down() && row_count > 0)
		{
			int step = (int)ui::repeat(rl::RLKeyboardKey.DOWN) - (int)ui::repeat(rl::RLKeyboardKey.UP);
			if (step)
			{
				int current = selected == -2 ? 0 : selected < 0 ? -1 : selected + parent_rows;
				int next = current < 0 ? (step > 0 ? 0 : row_count - 1) : math::clamp(current + step, 0, row_count - 1);
				if (ui::shift_down() && visible_count)
				{
					// Ranges never include the parent row.
					next = math::max(next, parent_rows);
					int vi = next - parent_rows;
					if (anchor < 0) anchor = selected >= 0 ? selected : vi;
					clear_marks();
					mark_range(anchor, vi);
					select_entry(vi);
				}
				else
				{
					select_only(next < parent_rows ? -2 : next - parent_rows);
				}
				collapse_row = -1;
				float y = (float)next * row_h;
				if (y < scroll) scroll = y;
				if (y + row_h > scroll + list.height) scroll = y + row_h - list.height;
				pressed_entry = -1;
				pressed_row = -1;
				last_click_row = -1;
				dragging = false;
			}
			if (rl::is_key_pressed(rl::RLKeyboardKey.ENTER))
			{
				if (selected == -2) { go_up = true; }
				else if (marked_count > 1) { multi_enter = true; }
				if (selected >= 0) { enter = visible[selected]; }
			}
		}
		scroll = ui::scroll_wheel(list, scroll, content);
		update_band(list, row_h, parent_rows, content);
		bool dim_cut = any_cut && ops::is_cut(txt::view(&directory));
		ui::begin_clip(list);
		// Virtualized list: visit only the rows that can actually be seen.
		int first = math::max(0, (int)(scroll / row_h));
		int end = math::min(row_count, first + (int)(list.height / row_h) + 2);
		for (int i = first; i < end; i++)
		{
			Rect row = { list.x, list.y + (float)i * row_h - scroll, list.width - 10, row_h };
			bool hovered = ui::hover(row);
			bool clicked = ui::clicked(row);
			bool activated;
			if (clicked)
			{
				pressed_row = i;
				ui::unfocus();
			}
			if (pressed_row == i && hovered && ui::live() && rl::is_mouse_button_released(rl::RLMouseButton.LEFT))
			{
				activated = !ctrl && !shift && last_click_row == i && ui::now - last_click_time <= 0.4;
				if (collapse_row == i - parent_rows && !dragging) select_only(collapse_row);
				collapse_row = -1;
				last_click_row = activated ? -1 : i;
				last_click_time = ui::now;
			}
			if (parent_rows && i == 0)
			{
				if (selected == -2) { ui::panel(row, ui::BG2, 4); }
				else if (hovered) { ui::panel(row, ui::BG1, 4); }
				if (hovered) hover_parent_row = true;
				if (dragging && hovered)
				{
					txt::set(&drop_target, txt::dirname(txt::view(&directory)));
					ui::outline(row, ui::AQUA, 4, 2);
				}
				ui::text(ui::I_FOLDER, row.x + 12 * content_scale, row.y + (row_h - icon_size) / 2, icon_size, ui::BG4);
				ui::text("../", row.x + 60 * content_scale, row.y + (row_h - text_size) / 2, text_size, ui::FG);
				if (clicked) { select_only(-2); go_up = true; }
				continue;
			}
			int vi = i - parent_rows;
			sys::Entry* entry = &entries[visible[vi]];
			if (marked[vi]) { ui::panel(row, ui::BG2, 4); }
			else if (hovered) { ui::panel(row, ui::BG1, 4); }
			if (selected == vi && (marked_count > 1 || !marked[vi])) ui::outline(row, ui::BG4, 4);
			if (hovered && entry.dir) hover_dir_entry = visible[vi];
			bool drop_here = dragging && hovered && entry.dir && !marked[vi];
			if (drop_here)
			{
				txt::set(&drop_target, txt::join(txt::view(&directory), txt::view(&entry.name)));
				ui::outline(row, ui::AQUA, 4, 2);
			}
			bool dim = dim_cut && cut_entry[visible[vi]];
			ui::text(entry.dir ? ui::I_FOLDER : ui::I_FILE, row.x + 12 * content_scale, row.y + (row_h - icon_size) / 2, icon_size, dim ? ui::BG4 : entry.dir ? ui::YELLOW : ui::GRAY);
			ui::text_fit(txt::view(&entry.name), row.x + 60 * content_scale, row.y + (row_h - text_size) / 2, math::max(0.0f, row.width - 72 * content_scale), text_size, dim ? ui::GRAY : ui::FG);
			if (clicked)
			{
				collapse_row = -1;
				// Blank space right of the name starts a selection box instead of a file drag (measured on press only).
				float name_end = row.x + 60 * content_scale + ui::text_w(txt::view(&entry.name), text_size) + 16 * content_scale;
				bool blank = rl::get_mouse_position()[0] > name_end;
				if (shift)
				{
					if (anchor < 0) anchor = selected >= 0 ? selected : vi;
					if (!ctrl) clear_marks();
					mark_range(anchor, vi);
					select_entry(vi);
				}
				else if (ctrl)
				{
					mark(vi, !marked[vi]);
					anchor = vi;
					select_entry(vi);
				}
				else if (marked[vi] && marked_count > 1)
				{
					// Keep the selection so it can be dragged; a plain release collapses it.
					collapse_row = vi;
					anchor = vi;
					select_entry(vi);
				}
				else
				{
					select_only(vi);
				}
				drag_dirs = 0;
				if (blank && !shift)
				{
					band_start(rl::get_mouse_position()[0], rl::get_mouse_position()[1] - list.y + scroll);
				}
				else if (!ctrl && !shift && marked[vi])
				{
					// Counted once per press, never per frame.
					for (int k = 0; k < visible_count; k++) if (marked[k] && entries[visible[k]].dir) drag_dirs++;
					pressed_entry = visible[vi];
					press_at = rl::get_mouse_position();
					dragging = false;
					txt::set(&drag_path, txt::join(txt::view(&directory), txt::view(&entry.name)));
				}
			}
			// Activate only after a completed double-click, never after a drag.
			if (activated && !dragging) enter = visible[vi];
		}
		if (!visible_count) ui::text(txt::empty(&search) ? "Empty folder" : "No matching files", list.x + 16 * content_scale, list.y + (float)parent_rows * row_h + 16 * content_scale, text_size, ui::GRAY);
		// A press on empty list space clears the selection (unless Ctrl/Shift) and may start a selection box.
		if (ui::clicked(list))
		{
			ui::unfocus();
			if (!ctrl && !shift) select_only(-1);
			band_start(rl::get_mouse_position()[0], rl::get_mouse_position()[1] - list.y + scroll);
		}
		draw_band(list);
		ui::end_clip();
		ui::scrollbar(list, scroll, content);
		// Navigate after drawing: do not mutate the entry array during iteration.
		if (go_up) { go(txt::dirname(txt::view(&directory))); }
		else if (multi_enter && launch_marked()) {}
		else if (enter >= 0)
		{
			String path = txt::join(txt::view(&directory), txt::view(&entries[enter].name));
			if (entries[enter].dir) { go(path); }
			else { openers::launch(path); }
		}
	}
	if (show_preview && preview::active) preview::draw(preview_panel);
	ops::draw_panel(ops_panel);
	ui::panel({ 0, h - 28, w, 28 }, ui::BG_HARD);
	update_info(trash_top);
	poll_selection_size();
	if (txt::empty(&info_name) && txt::empty(&info_detail))
	{
		ui::text(txt::view(&status), 16, h - 22, 16, ui::GRAY);
	}
	else
	{
		// Selection details left, folder item count right.
		float right = w - 16 - status_w;
		ui::text(txt::view(&status), right, h - 22, 16, ui::GRAY);
		float name_w = math::min(info_name_w, (right - 40) * (deep ? 0.6f : 0.5f));
		if (deep) { ui::text_tail(txt::view(&info_name), 16, h - 22, name_w, 16, ui::FG); }
		else { ui::text_fit(txt::view(&info_name), 16, h - 22, name_w, 16, ui::FG); }
		ui::text_fit(txt::view(&info_detail), 16 + name_w + 12, h - 22, math::max(0.0f, right - name_w - 52), 16, ui::FG4);
	}
	finish_drag(h);
	if (rl::is_mouse_button_released(rl::RLMouseButton.LEFT) || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { pressed_row = -1; collapse_row = -1; }
	if (!searching && ui::focused(ID_PATH)) complete::draw(path_field);
	settings::draw();
	ops::draw_dialogs();
	ui::frame_end();
}
