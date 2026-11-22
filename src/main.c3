module sms;
import std::math, std::core::string, std::io;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys;
import sms::prefs;

const int ID_PATH = 1;
const int MAX_ENTRIES = 16384;
const float ROW = 42;
const float SIDE_W = 184;
const float SIDE_ROW = 40;
char[4096] directory;
char[4096] path_edit;
sys::Entry[MAX_ENTRIES] entries;
int entry_count;
int[MAX_ENTRIES] visible;
int visible_count;
int selected = -1;
float scroll;
char[128] status;
float sidebar_scroll;
int pressed_entry = -1;
bool dragging;
rl::RLVector2 press_at;
char[4096] drag_path;

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
				io::printn("Usage: sms [--dir PATH | -d PATH]\nDefaults to the working directory. Click a folder to enter it.\nCtrl+L: edit path; Ctrl+H: toggle hidden files; Ctrl+S: toggle sidebar; Backspace: parent; F5: refresh.");
				return 0;
			default:
				io::eprintfn("sms: unknown option: %s", args[i]); return 2;
		}
	}
	prefs::load();
	defer { if (!prefs::save()) io::eprintfn("sms: could not save settings"); }
	if (!navigate(start)) { io::eprintfn("sms: cannot read folder: %s", start); return 1; }
	ui::open("sms", 900, 640, 480, 320);
	defer ui::close();
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
	txt::set(&directory, txt::view(&resolved));
	txt::set(&path_edit, txt::view(&directory));
	refilter();
	return true;
}

// Toggle against the cached listing: no disk I/O or sorting needed.
fn void refilter() => @pool()
{
	visible_count = 0;
	for (int i = 0; i < entry_count; i++)
	{
		if (prefs::hidden || entries[i].name[0] != '.') visible[visible_count++] = i;
	}
	txt::set(&status, string::tformat("%d items%s%s", visible_count,
		prefs::hidden ? " · hidden shown" : "",
		entry_count == MAX_ENTRIES ? " (display limit reached)" : ""));
	selected = -1;
	scroll = 0;
	pressed_entry = -1;
	dragging = false;
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
fn void sidebar_location(Rect row, String path, String name, String icon)
{
	if (path == txt::view(&directory)) ui::panel(row, ui::BG2, 4);
	if (ui::hover(row))
	{
		ui::panel(row, ui::BG1, 4);
		ui::tooltip(path);
	}
	ui::text(icon, row.x + 8, row.y + 8, 23, ui::YELLOW);
	ui::text_fit(name, row.x + 40, row.y + 12, row.width - 44, 16, ui::FG);
	if (ui::clicked(row)) go(path);
}

fn void draw_sidebar(float h)
{
	Rect bar = { 0, 60, SIDE_W, h - 88 };
	ui::panel(bar, ui::BG_HARD);
	if (dragging && ui::point_in(rl::get_mouse_position(), bar)) ui::outline(bar, ui::AQUA, 0, 2);
	ui::text("LOCATIONS", 16, 77, 12, ui::GRAY);
	if (ui::icon_button({ SIDE_W - 42, 68, 30, 30 }, ui::I_PLUS, ui::FG4, "Add current folder (or drag a folder here)")) add_location(txt::view(&directory));
	sidebar_location({ 8, 104, SIDE_W - 16, 40 }, sys::home(), "Home", ui::I_HOME);
	sidebar_location({ 8, 144, SIDE_W - 16, 40 }, "/", "File system", ui::I_HDD);
	ui::hline(12, 192, SIDE_W - 24);
	Rect area = { 8, 204, SIDE_W - 16, h - 240 };
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

fn void finish_drag(float h)
{
	Rect bar = { 0, 60, SIDE_W, h - 88 };
	bool over_bar = prefs::sidebar && ui::point_in(rl::get_mouse_position(), bar);
	if (pressed_entry >= 0 && rl::is_mouse_button_released(rl::RLMouseButton.LEFT))
	{
		if (dragging && over_bar && ui::top == 0) add_location(txt::view(&drag_path));
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
		ui::panel({ mouse[0] + 14, mouse[1] + 14, 210, 42 }, ui::BG_HARD, 4);
		ui::text(ui::I_FOLDER, mouse[0] + 24, mouse[1] + 22, 23, ui::YELLOW);
		ui::text_fit(txt::basename(txt::view(&drag_path)), mouse[0] + 56, mouse[1] + 27, 154, 16, ui::FG);
	}
}

fn void frame() => @pool()
{
	ui::frame_begin();
	update_drag();
	float w = ui::sw();
	float h = ui::sh();
	if (ui::top == 0 && ui::ctrl_down() && ui::letter('l')) ui::focus_on(ID_PATH, &path_edit);
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
	}
	ui::panel({ 0, 0, w, 60 }, ui::BG_HARD);
	if (ui::icon_button({ 12, 12, 36, 36 }, ui::I_UP, ui::FG4, "Parent folder (Backspace)")) go(txt::dirname(txt::view(&directory)));
	if (ui::icon_button({ 52, 12, 36, 36 }, ui::I_HOME, ui::FG4, "Home")) go(sys::home());
	bool submitted;
	ui::input(ID_PATH, { 100, 12, w - 152, 36 }, &path_edit, "Folder path", &submitted, ui::I_FOLDER);
	if (submitted) go(txt::view(&path_edit));
	if (ui::icon_button({ w - 44, 12, 32, 36 }, ui::I_REFRESH, ui::FG4, "Refresh (F5)")) go(txt::view(&directory));
	ui::hline(0, 59, w);

	float left = 8;
	if (prefs::sidebar)
	{
		draw_sidebar(h);
		left = SIDE_W + 8;
	}
	Rect list = { left, 68, w - left - 8, h - 104 };
	float content = (float)visible_count * ROW;
	scroll = ui::scroll_wheel(list, scroll, content);
	ui::begin_clip(list);
	// Virtualized list: visit only the rows that can actually be seen.
	int first = math::max(0, (int)(scroll / ROW));
	int end = math::min(visible_count, first + (int)(list.height / ROW) + 2);
	int enter = -1;
	for (int i = first; i < end; i++)
	{
		Rect row = { list.x, list.y + (float)i * ROW - scroll, list.width - 10, ROW };
		sys::Entry* entry = &entries[visible[i]];
		bool hovered = ui::hover(row);
		if (selected == i) { ui::panel(row, ui::BG2, 4); }
		else if (hovered) { ui::panel(row, ui::BG1, 4); }
		ui::text(entry.dir ? ui::I_FOLDER : ui::I_FILE, row.x + 12, row.y + 8, 25, entry.dir ? ui::YELLOW : ui::GRAY);
		ui::text_fit(txt::view(&entry.name), row.x + 50, row.y + 13, row.width - 62, 17, ui::FG);
		if (ui::clicked(row))
		{
			selected = i;
			ui::unfocus();
			if (entry.dir)
			{
				pressed_entry = visible[i];
				press_at = rl::get_mouse_position();
				dragging = false;
				txt::set(&drag_path, txt::join(txt::view(&directory), txt::view(&entry.name)));
			}
		}
		// Opening on release leaves room for a drag without opening the folder first.
		if (entry.dir && pressed_entry == visible[i] && !dragging && hovered && ui::live() && rl::is_mouse_button_released(rl::RLMouseButton.LEFT)) enter = visible[i];
	}
	if (!visible_count) ui::text("Empty folder", list.x + 16, list.y + 16, 15, ui::GRAY);
	ui::end_clip();
	ui::scrollbar(list, scroll, content);
	// Navigate after drawing: do not mutate the entry array during iteration.
	if (enter >= 0) go(txt::join(txt::view(&directory), txt::view(&entries[enter].name)));
	ui::panel({ 0, h - 28, w, 28 }, ui::BG_HARD);
	ui::text(txt::view(&status), 16, h - 21, 13, ui::GRAY);
	finish_drag(h);
	ui::frame_end();
}
