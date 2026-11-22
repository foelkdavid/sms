module sms;
import std::math, std::core::string, std::io;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys;

const int ID_PATH = 1;
const int MAX_ENTRIES = 16384;
const float ROW = 32;
char[4096] directory;
char[4096] path_edit;
sys::Entry[MAX_ENTRIES] entries;
int entry_count;
int selected = -1;
float scroll;
char[128] status;

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
				io::printn("Usage: sms [--dir PATH | -d PATH]\nDefaults to the working directory. Click a folder to enter it.\nCtrl+L: edit path; Backspace: parent; F5: refresh.");
				return 0;
			default:
				io::eprintfn("sms: unknown option: %s", args[i]); return 2;
		}
	}
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
	txt::set(&status, string::tformat(n == MAX_ENTRIES ? "%d items (display limit reached)" : "%d items", n));
	selected = -1;
	scroll = 0;
	return true;
}

fn void go(String path)
{
	if (navigate(path)) { ui::unfocus(); }
	else { ui::toast("Cannot read this folder", ui::RED); }
}

fn void frame() => @pool()
{
	ui::frame_begin();
	float w = ui::sw();
	float h = ui::sh();
	if (ui::top == 0 && ui::ctrl_down() && ui::letter('l')) ui::focus_on(ID_PATH, &path_edit);
	if (ui::top == 0 && ui::focus < 0)
	{
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

	Rect list = { 8, 68, w - 16, h - 104 };
	float content = (float)entry_count * ROW;
	scroll = ui::scroll_wheel(list, scroll, content);
	ui::begin_clip(list);
	// Virtualized list: visit only the rows that can actually be seen.
	int first = math::max(0, (int)(scroll / ROW));
	int end = math::min(entry_count, first + (int)(list.height / ROW) + 2);
	int enter = -1;
	for (int i = first; i < end; i++)
	{
		Rect row = { list.x, list.y + (float)i * ROW - scroll, list.width - 10, ROW };
		bool hovered = ui::hover(row);
		if (selected == i) { ui::panel(row, ui::BG2, 4); }
		else if (hovered) { ui::panel(row, ui::BG1, 4); }
		ui::text(entries[i].dir ? ui::I_FOLDER : ui::I_FILE, row.x + 12, row.y + 7, 17, entries[i].dir ? ui::YELLOW : ui::GRAY);
		ui::text_fit(txt::view(&entries[i].name), row.x + 42, row.y + 8, row.width - 54, 15, ui::FG);
		if (ui::clicked(row))
		{
			selected = i;
			ui::unfocus();
			if (entries[i].dir) enter = i;
		}
	}
	if (!entry_count) ui::text("Empty folder", list.x + 16, list.y + 16, 15, ui::GRAY);
	ui::end_clip();
	ui::scrollbar(list, scroll, content);
	// Navigate after drawing: do not mutate the entry array during iteration.
	if (enter >= 0) go(txt::join(txt::view(&directory), txt::view(&entries[enter].name)));
	ui::panel({ 0, h - 28, w, 28 }, ui::BG_HARD);
	ui::text(txt::view(&status), 16, h - 21, 13, ui::GRAY);
	ui::frame_end();
}
