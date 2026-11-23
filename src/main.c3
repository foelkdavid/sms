module sms;
import std::math, std::core::string, std::io;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::fileop;
import sms::prefs, sms::preview, sms::settings, sms::openers, sms::ops;

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
char[64] sel_status;
int sel_status_count = -1;
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
				io::printn("Usage: sms [--dir PATH | -d PATH]\nDefaults to the working directory. Double-click or press Enter to open selected folders/files. Ctrl+K configures file openers.\nClick selects; Ctrl+click toggles; Shift+click / Shift+Up/Down select a range; drag on empty space draws a selection box; Ctrl+A selects all; Escape or a click on empty space clears.\nCtrl+C / Ctrl+X / Ctrl+V: copy / cut / paste (with progress and cancel); Delete: trash (Shift+Delete: permanent); drag onto a folder moves (Ctrl copies).\nCtrl+L: edit path; Ctrl+F: search current folder (Escape clears); Ctrl+H: toggle hidden files; Ctrl+S: toggle sidebar; Ctrl+K: settings; Backspace: parent; F5: refresh.\nCtrl +/-/0: content zoom; Ctrl+Shift +/-/0: UI zoom (both remembered).");
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
	txt::set(&directory, txt::view(&resolved));
	txt::set(&path_edit, txt::view(&directory));
	searching = false;
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
	char[256] keep_search = search;
	if (!navigate(txt::view(&directory).tcopy())) return;
	if (was_searching)
	{
		searching = true;
		search = keep_search;
		refilter();
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

fn void close_search()
{
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
fn void sidebar_location(Rect row, String path, String name, String icon, bool trash = false)
{
	if (path == txt::view(&directory)) ui::panel(row, ui::BG2, 4);
	if (ui::hover(row))
	{
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
	ui::text(icon, row.x + 8, row.y + 8, 23, ui::YELLOW);
	ui::text_fit(name, row.x + 40, row.y + 12, row.width - 44, 16, ui::FG);
	if (ui::clicked(row))
	{
		if (trash) ensure_trash();
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
		sidebar_location({ 8, 184, SIDE_W - 16, 40 }, txt::view(&trash_files), "Trash", ui::I_TRASH, true);
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

// Enter on a multi-selection launches the selected files (bounded by the opener slots).
// Returns false when no files are selected (folders only).
fn bool launch_marked() => @pool()
{
	bool found;
	for (int i = 0; i < visible_count; i++)
	{
		if (!marked[i] || entries[visible[i]].dir) continue;
		found = true;
		if (!openers::launch(txt::join(txt::view(&directory), txt::view(&entries[visible[i]].name)))) break;
	}
	return found;
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
	// External file-manager drops are checked once per drop, never every frame.
	if (rl::is_file_dropped())
	{
		rl::RLFilePathList dropped = rl::load_dropped_files();
		defer rl::unload_dropped_files(dropped);
		if (over_bar && ui::top == 0)
		{
			for (uint i = 0; i < dropped.count; i++)
			{
				String path = dropped.paths[i].str_view();
				if (!sys::is_dir(path)) continue;
				char[4096] resolved;
				sys::realpath(&resolved, path);
				add_location(txt::view(&resolved));
			}
		}
	}
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
	drop_trash = false;
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
			ui::focus_on(ID_PATH, &path_edit);
		}
		if (ui::ctrl_down() && ui::letter('f'))
		{
			searching = true;
			pressed_entry = -1;
			dragging = false;
			ui::focus_on(ID_SEARCH, &search);
		}
	}
	if (ui::top == 0 && ui::focus < 0)
	{
		if (ui::ctrl_down() && ui::letter('h'))
		{
			prefs::hidden = !prefs::hidden;
			prefs::dirty = true;
			refilter();
		}
		if (ui::ctrl_down() && ui::letter('s'))
		{
			prefs::sidebar = !prefs::sidebar;
			prefs::dirty = true;
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.BACKSPACE)) go(txt::dirname(txt::view(&directory)));
		if (rl::is_key_pressed(rl::RLKeyboardKey.F5)) go(txt::view(&directory));
		if (ui::ctrl_down() && ui::letter('a') && visible_count)
		{
			mark_range(0, visible_count - 1);
			if (selected < 0) { select_entry(0); }
			if (anchor < 0) anchor = selected;
		}
		if (!was_pressing && !searching && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { clear_marks(); anchor = -1; collapse_row = -1; }
		if (ui::ctrl_down() && (ui::letter('c') || ui::letter('x')) && marked_count)
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
		if (rl::is_key_pressed(rl::RLKeyboardKey.DELETE) && marked_count) ops::remove(txt::view(&directory), marked_names(), ui::shift_down() || in_trash());
	}
	ui::panel({ 0, 0, w, 60 }, ui::BG_HARD);
	if (ui::icon_button({ 12, 12, 36, 36 }, ui::I_UP, ui::FG4, "Parent folder (Backspace)")) go(txt::dirname(txt::view(&directory)));
	if (ui::icon_button({ 52, 12, 36, 36 }, ui::I_HOME, ui::FG4, "Home")) go(sys::home());
	bool submitted;
	if (searching)
	{
		if (ui::input(ID_SEARCH, { 100, 12, w - 192, 36 }, &search, "Search this folder", &submitted, ui::I_SEARCH)) refilter();
		if (submitted) ui::unfocus();
	}
	else
	{
		ui::input(ID_PATH, { 100, 12, w - 192, 36 }, &path_edit, "Folder path", &submitted, ui::I_FOLDER);
		if (submitted) go(txt::view(&path_edit));
	}
	if (ui::icon_button({ w - 84, 12, 32, 36 }, searching ? ui::I_TIMES : ui::I_SEARCH, ui::FG4, searching ? "Clear search (Escape)" : "Search this folder (Ctrl+F)"))
	{
		if (searching) { close_search(); }
		else { searching = true; ui::focus_on(ID_SEARCH, &search); }
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
	Rect list = { left, 68, w - left - 8 - (show_preview ? preview_w + 8 : 0), main_h };
	Rect preview_panel = { w - preview_w - 8, 68, preview_w, main_h };
	Rect ops_panel = { left, 68 + main_h + 8, w - left - 8, ops_h };
	int parent_rows = txt::view(&directory) == "/" || !txt::empty(&search) ? 0 : 1;
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
			if (dragging && hovered)
			{
				txt::set(&drop_target, txt::dirname(txt::view(&directory)));
				ui::outline(row, ui::AQUA, 4, 2);
			}
			ui::text(ui::I_UP, row.x + 12 * content_scale, row.y + (row_h - icon_size) / 2, icon_size, ui::YELLOW);
			ui::text("../", row.x + 60 * content_scale, row.y + (row_h - text_size) / 2, text_size, ui::FG);
			if (clicked) { select_only(-2); go_up = true; }
			continue;
		}
		int vi = i - parent_rows;
		sys::Entry* entry = &entries[visible[vi]];
		if (marked[vi]) { ui::panel(row, ui::BG2, 4); }
		else if (hovered) { ui::panel(row, ui::BG1, 4); }
		if (selected == vi && (marked_count > 1 || !marked[vi])) ui::outline(row, ui::BG4, 4);
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
	if (show_preview && preview::active) preview::draw(preview_panel);
	ops::draw_panel(ops_panel);
	ui::panel({ 0, h - 28, w, 28 }, ui::BG_HARD);
	ui::text(txt::view(&status), 16, h - 22, 16, ui::GRAY);
	if (marked_count != sel_status_count)
	{
		sel_status_count = marked_count;
		txt::set(&sel_status, marked_count > 1 ? string::tformat("%d selected", marked_count) : "");
	}
	if (!txt::empty(&sel_status)) ui::text(txt::view(&sel_status), w - 16 - ui::text_w(txt::view(&sel_status), 16), h - 22, 16, ui::FG4);
	finish_drag(h);
	if (rl::is_mouse_button_released(rl::RLMouseButton.LEFT) || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { pressed_row = -1; collapse_row = -1; }
	settings::draw();
	ops::draw_dialogs();
	ui::frame_end();
}
