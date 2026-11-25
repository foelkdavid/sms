module sms::settings;
import std::math;
import raylib6::rl;
import bmu::ui, bmu::txt;
import sms::openers, sms::openwith, sms::prefs;
import std::core::string, std::io, bmu::sys, bmu::fileop, bmu::places;

bool open;
int tab;
float shortcuts_scroll;
float rules_scroll;
float targets_scroll;
const float RULE_ROW = 44;
const int ID_TERMINAL = 90;
const int ID_OPERATIONS = 91;
ui::Shortcut[*] shortcuts = {
	{ "NAVIGATION", "", true },
	{ "Up / Down", "Move selection (hold to repeat)", false },
	{ "Enter", "Open selected folder, or open selected files", false },
	{ "Backspace / -", "Go to parent folder", false },
	{ "Ctrl + L", "Edit folder path; Enter to go", false },
	{ "Tab in path bar", "Complete folder (common part, then the highlighted one)", false },
	{ "Up / Down in path bar", "Choose a suggested folder", false },
	{ "F5", "Re-read the folder (changes by other programs show up by themselves)", false },
	{ "SELECTION", "", true },
	{ "Ctrl + click", "Add / remove one item", false },
	{ "Shift + click", "Select a range (Ctrl + Shift adds it)", false },
	{ "Shift + Up / Down", "Extend the selection", false },
	{ "Ctrl + A", "Select all", false },
	{ "S", "Size selected folders, or this folder if nothing is selected", false },
	{ "Drag on empty space", "Draw a selection box (Ctrl adds)", false },
	{ "Escape / click empty", "Clear the selection", false },
	{ "FILES", "", true },
	{ "Ctrl + C / Ctrl + X", "Copy / cut selected items (also for other sms windows and file managers)", false },
	{ "Ctrl + V", "Paste into this folder (files copied in any sms window or file manager)", false },
	{ "Ctrl + N", "New folder", false },
	{ "Ctrl + Shift + N", "New (empty) file", false },
	{ "Delete", "Move to trash (or delete, see General)", false },
	{ "Shift + Delete", "Delete permanently (asks first)", false },
	{ "Drag onto a folder", "Move there; hold Ctrl to copy", false },
	{ "Drag out of the window", "Into another sms window: move there; hold Ctrl to copy", false },
	{ "Drop from another app", "Copy into the folder under the pointer (Trash: trash)", false },
	{ "Restore (in Trash)", "Put selected items back where they came from", false },
	{ "ARCHIVES", "", true },
	{ "Enter / double click", "Browse an archive (zip, tar, 7z, rar, …) unless an opener matches", false },
	{ "Right click an archive", "Browse, Extract here, Extract to…", false },
	{ "Inside an archive", "Read only; double click opens a temporary copy (see General)", false },
	{ "Right click inside", "Extract the selection next to the archive, or to a folder", false },
	{ "Ctrl + C inside", "Copy entries; Ctrl + V in a folder extracts them", false },
	{ "Drag onto ../", "At the archive's top: extract into the folder holding it", false },
	{ "SEARCH & VIEW", "", true },
	{ "Ctrl + F", "Search this folder", false },
	{ "Ctrl + Shift + F", "Search all subfolders (full path below)", false },
	{ "Enter / Tab / Down in search", "Keep results, select the first one", false },
	{ "Ctrl + H", "Show / hide hidden files", false },
	{ "Ctrl + S", "Show / hide sidebar", false },
	{ "Escape", "Clear search, cancel drag, close settings", false },
	{ "Ctrl + K", "Open / close settings", false },
	{ "ZOOM", "", true },
	{ "Ctrl + / -", "Resize file-list content", false },
	{ "Ctrl + 0", "Reset file-list zoom to 100%", false },
	{ "Ctrl + Shift + / -", "Resize the whole interface", false },
	{ "Ctrl + Shift + 0", "Reset interface zoom", false },
	{ "MOUSE", "", true },
	{ "Single click", "Select a file or folder", false },
	{ "Double click", "Open a file or folder", false },
	{ "Right click a file", "Open, Open with …, Move to trash; archives: extract; New", false },
	{ "Right click a folder", "Open, Open in new window, open in the terminal (General), Move to trash", false },
	{ "Middle click a folder", "Open it in a new sms window (also locations)", false },
	{ "Right click free space", "Open terminal here, New folder, New file", false },
	{ "Shift + right click", "The programs as sudo (asks for the password), Delete permanently", false },
	{ "Right click a location", "Open, open in the terminal, Open with … (Shift: as sudo)", false },
	{ "Right click Trash", "Open, Empty trash (asks first; also the red button in the Trash)", false },
	{ "Open with …", "Your own programs in these menus (Ctrl+K → Open with)", false },
	{ "Click ../", "Go to parent folder", false },
	{ "Drag onto ../ or a place", "Move there; hold Ctrl to copy", false },
	{ "Drag onto sidebar", "Drop folders on empty sidebar space to save them", false },
	{ "Close window", "Asks first while a file operation runs", false }
};

<* About tab: bmu's standard rows plus sms's own; collected when the tab opens (never per frame). *>
fn void collect_about() => @pool()
{
	ui::about_reset("sms", env::PROJECT_VERSION);
	ui::about_add("File list", string::tformat("%d%%", prefs::content_percent));
	ui::about_add("Settings", txt::view(&prefs::config_dir));
	char[4096] trash;
	fileop::trash_dir(&trash);
	ui::about_add("Trash", prefs::trash ? txt::view(&trash) : "disabled (Delete is permanent)");
}

fn void toggle()
{
	open = !open;
	ui::unfocus();
}

fn void draw()
{
	if (!open) return;
	if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { open = false; ui::unfocus(); return; }
	ui::layer = 1;
	Rect box = ui::dialog(780, 600);
	if (ui::dialog_header(box, ui::I_GEAR, "Settings")) { open = false; ui::unfocus(); ui::layer = 0; return; }
	float x = box.x + 16;
	float width = box.width - 32;
	float y = box.y + 54;
	float tab_w = (width - 32) / 5;
	if (ui::button({ x, y, tab_w, 36 }, "Shortcuts", tab == 0 ? PRIMARY : NORMAL)) { tab = 0; ui::unfocus(); }
	if (ui::button({ x + tab_w + 8, y, tab_w, 36 }, "File openers", tab == 1 ? PRIMARY : NORMAL)) { tab = 1; ui::unfocus(); }
	if (ui::button({ x + (tab_w + 8) * 2, y, tab_w, 36 }, "Open with", tab == 4 ? PRIMARY : NORMAL)) { tab = 4; ui::unfocus(); }
	if (ui::button({ x + (tab_w + 8) * 3, y, tab_w, 36 }, "General", tab == 2 ? PRIMARY : NORMAL)) { tab = 2; ui::unfocus(); }
	if (ui::button({ x + (tab_w + 8) * 4, y, tab_w, 36 }, "About", tab == 3 ? PRIMARY : NORMAL)) { tab = 3; ui::unfocus(); collect_about(); }
	Rect area = { x, y + 48, width, box.height - 118 };
	if (tab == 0)
	{
		shortcuts_scroll = ui::shortcut_table(area, &shortcuts, shortcuts_scroll);
	}
	else if (tab == 3)
	{
		ui::about_draw(area);
	}
	else if (tab == 4)
	{
		draw_open_with(box, area, x, width);
	}
	else if (tab == 2)
	{
		if (ui::checkbox(x + 4, area.y + 8, "Enable Trash", &prefs::trash)) { prefs::dirty = true; places::set_trash(prefs::trash); }
		if (ui::checkbox(x + 4, area.y + 48, "Enable Archive copies", &prefs::archive_open)) prefs::dirty = true;
		bool dl = places::downloads;
		if (ui::checkbox(x + 4, area.y + 88, "Show Downloads in Sidebar", &dl)) places::set_downloads(dl);
		ui::label(x + 4, area.y + 136, "TERMINAL");
		if (ui::input(ID_TERMINAL, { x + 4, area.y + 156, width - 8, 36 }, &prefs::terminal, "foot", null, ui::I_TERMINAL)) prefs::dirty = true;
		ui::label(x + 4, area.y + 212, "SEVERAL FILE OPERATIONS");
		int mode = prefs::operations;
		if (ui::dropdown(ID_OPERATIONS, { x + 4, area.y + 232, width - 8, 36 }, { "Auto: copies on the same drive one after another, the rest at once", "One after another", "All at once" }, &mode))
		{
			prefs::operations = mode;
			prefs::dirty = true;
		}
	}
	else
	{
		bool compact = box.height < 360;
		float bottom = box.y + box.height - (compact ? 70 : 94);
		if (!compact) ui::text_fit("Group patterns with commas. First match wins. Command + arguments, no shell; the file goes last.", x, area.y, width, 14, ui::FG4);
		float pattern_w = (width - 66) * 0.48f;
		float executable_x = x + pattern_w + 12;
		float executable_w = width - pattern_w - 62;
		float label_y = area.y + (compact ? 0 : 28);
		ui::label(x, label_y, "FILENAME PATTERNS");
		ui::label(executable_x, label_y, "OPEN WITH");
		area.y += compact ? 20 : 52;
		area.height = math::max(20.0f, bottom - area.y - 12);
		float content = (float)openers::count * RULE_ROW;
		rules_scroll = ui::scroll_wheel(area, rules_scroll, content);
		ui::begin_clip(area);
		int first = math::max(0, (int)(rules_scroll / RULE_ROW));
		int end = math::min(openers::count, first + (int)(area.height / RULE_ROW) + 2);
		int remove = -1;
		for (int i = first; i < end; i++)
		{
			float row_y = area.y + (float)i * RULE_ROW - rules_scroll;
			ui::input(100 + i * 2, { x, row_y, pattern_w, 36 }, &openers::rules[i].pattern, "*.png,*.jpg,*.jpeg");
			ui::input(101 + i * 2, { executable_x, row_y, executable_w, 36 }, &openers::rules[i].executable, "alacritty -e vim");
			if (ui::icon_button({ x + width - 44, row_y, 32, 32 }, ui::I_TIMES, ui::GRAY, "Remove rule")) remove = i;
		}
		ui::end_clip();
		ui::scrollbar(area, rules_scroll, content);
		if (remove >= 0)
		{
			ui::unfocus();
			for (int i = remove; i + 1 < openers::count; i++) openers::rules[i] = openers::rules[i + 1];
			openers::count--;
		}
		ui::text_fit(txt::view(&openers::error), x, bottom, width, 14, ui::RED);
		if (!compact) ui::text_fit(openers::config_path(), x, bottom + 20, width, 13, ui::GRAY);
		float buttons_y = bottom + (compact ? 26 : 42);
		if (ui::button({ x, buttons_y, 116, 36 }, "Add rule", enabled: openers::count < openers::MAX_RULES))
		{
			openers::rules[openers::count] = {};
			openers::count++;
			rules_scroll = (float)openers::count * RULE_ROW;
		}
		if (ui::button({ x + 124, buttons_y, 116, 36 }, "Save", PRIMARY))
		{
			ui::unfocus();
			if (openers::save()) ui::toast("File openers saved");
		}
	}
	ui::layer = 0;
}

<* "Open with" tab: name + command per entry (icon from the program), saved explicitly like the openers. *>
fn void draw_open_with(Rect box, Rect area, float x, float width) => @pool()
{
	bool compact = box.height < 360;
	float bottom = box.y + box.height - (compact ? 70 : 94);
	if (!compact) ui::text_fit("Right-click menus offer \"Open with NAME\". Command + arguments, no shell; the paths go last.", x, area.y, width, 14, ui::FG4);
	float name_w = (width - 66) * 0.32f;
	float command_x = x + 40 + name_w + 12;
	float command_w = width - name_w - 102;
	float label_y = area.y + (compact ? 0 : 28);
	ui::label(x + 40, label_y, "NAME");
	ui::label(command_x, label_y, "COMMAND");
	area.y += compact ? 20 : 52;
	area.height = math::max(20.0f, bottom - area.y - 12);
	float content = (float)openwith::count * RULE_ROW;
	targets_scroll = ui::scroll_wheel(area, targets_scroll, content);
	ui::begin_clip(area);
	int first = math::max(0, (int)(targets_scroll / RULE_ROW));
	int end = math::min(openwith::count, first + (int)(area.height / RULE_ROW) + 2);
	int remove = -1;
	for (int i = first; i < end; i++)
	{
		float row_y = area.y + (float)i * RULE_ROW - targets_scroll;
		String glyph = openwith::icon[i];
		if (glyph.len) ui::text(glyph, x + 6, row_y + 6, 22, ui::FG4);
		ui::input(300 + i * 2, { x + 40, row_y, name_w, 36 }, &openwith::targets[i].name, "Emacs");
		ui::input(301 + i * 2, { command_x, row_y, command_w, 36 }, &openwith::targets[i].command, "emacs");
		if (ui::icon_button({ x + width - 44, row_y, 32, 32 }, ui::I_TIMES, ui::GRAY, "Remove entry")) remove = i;
	}
	ui::end_clip();
	ui::scrollbar(area, targets_scroll, content);
	if (remove >= 0)
	{
		ui::unfocus();
		for (int i = remove; i + 1 < openwith::count; i++)
		{
			openwith::targets[i] = openwith::targets[i + 1];
			openwith::icon[i] = openwith::icon[i + 1];
		}
		openwith::count--;
	}
	ui::text_fit(txt::view(&openwith::error), x, bottom, width, 14, ui::RED);
	if (!compact) ui::text_fit(openwith::config_path(), x, bottom + 20, width, 13, ui::GRAY);
	float buttons_y = bottom + (compact ? 26 : 42);
	if (ui::button({ x, buttons_y, 116, 36 }, "Add entry", enabled: openwith::count < openwith::MAX_TARGETS))
	{
		openwith::targets[openwith::count] = {};
		openwith::icon[openwith::count] = "";
		openwith::count++;
		targets_scroll = (float)openwith::count * RULE_ROW;
	}
	if (ui::button({ x + 124, buttons_y, 116, 36 }, "Save", PRIMARY))
	{
		ui::unfocus();
		if (openwith::save()) ui::toast("Open with saved");
	}
}
