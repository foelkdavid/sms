module sms::settings;
import std::math;
import raylib6::rl;
import bmu::ui, bmu::txt;
import sms::openers, sms::prefs;

bool open;
int tab;
float shortcuts_scroll;
float rules_scroll;
const float SHORTCUT_ROW = 38;
const float RULE_ROW = 44;
struct Shortcut
{
	String keys;
	String action;
	bool heading;
}
Shortcut[39] shortcuts = {
	{ "NAVIGATION", "", true },
	{ "Up / Down", "Move selection (hold to repeat)", false },
	{ "Enter", "Open selected folder, or open selected files", false },
	{ "Backspace", "Go to parent folder", false },
	{ "Ctrl + L", "Edit folder path; Enter to go", false },
	{ "F5", "Refresh current folder", false },
	{ "SELECTION", "", true },
	{ "Ctrl + click", "Add / remove one item", false },
	{ "Shift + click", "Select a range (Ctrl + Shift adds it)", false },
	{ "Shift + Up / Down", "Extend the selection", false },
	{ "Ctrl + A", "Select all", false },
	{ "Drag on empty space", "Draw a selection box (Ctrl adds)", false },
	{ "Escape / click empty", "Clear the selection", false },
	{ "FILES", "", true },
	{ "Ctrl + C / Ctrl + X", "Copy / cut selected items", false },
	{ "Ctrl + V", "Paste into this folder", false },
	{ "Delete", "Move to trash (or delete, see General)", false },
	{ "Shift + Delete", "Delete permanently (asks first)", false },
	{ "Drag onto a folder", "Move there; hold Ctrl to copy", false },
	{ "Restore (in Trash)", "Put selected items back where they came from", false },
	{ "SEARCH & VIEW", "", true },
	{ "Ctrl + F", "Search this folder", false },
	{ "Enter in search", "Keep filter and focus file list", false },
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
	{ "Click ../", "Go to parent folder", false },
	{ "Drag onto ../ or a place", "Move there; hold Ctrl to copy", false },
	{ "Drag onto sidebar", "Drop folders on empty sidebar space to save them", false },
	{ "Close window", "Asks first while a file operation runs", false }
};

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
	float tab_w = (width - 16) / 3;
	if (ui::button({ x, y, tab_w, 36 }, "Keyboard shortcuts", tab == 0 ? PRIMARY : NORMAL)) { tab = 0; ui::unfocus(); }
	if (ui::button({ x + tab_w + 8, y, tab_w, 36 }, "File openers", tab == 1 ? PRIMARY : NORMAL)) { tab = 1; ui::unfocus(); }
	if (ui::button({ x + (tab_w + 8) * 2, y, tab_w, 36 }, "General", tab == 2 ? PRIMARY : NORMAL)) { tab = 2; ui::unfocus(); }
	Rect area = { x, y + 48, width, box.height - 118 };
	if (tab == 0)
	{
		float content = (float)shortcuts.len * SHORTCUT_ROW;
		shortcuts_scroll = ui::scroll_wheel(area, shortcuts_scroll, content);
		ui::begin_clip(area);
		int first = math::max(0, (int)(shortcuts_scroll / SHORTCUT_ROW));
		int end = math::min((int)shortcuts.len, first + (int)(area.height / SHORTCUT_ROW) + 2);
		float key_w = math::min(184.0f, (width - 40) * 0.45f);
		for (int i = first; i < end; i++)
		{
			float row_y = area.y + (float)i * SHORTCUT_ROW - shortcuts_scroll;
			Shortcut* shortcut = &shortcuts[i];
			if (shortcut.heading)
			{
				ui::text(shortcut.keys, x + 8, row_y + 13, 13, ui::YELLOW);
				ui::hline(x + 146, row_y + 21, width - 166, ui::BG2);
				continue;
			}
			ui::panel({ x, row_y + 2, width - 12, SHORTCUT_ROW - 4 }, ui::BG_HARD, 4);
			ui::panel({ x + 6, row_y + 6, key_w, SHORTCUT_ROW - 12 }, ui::BG1, 4);
			ui::outline({ x + 6, row_y + 6, key_w, SHORTCUT_ROW - 12 }, ui::BG2, 4);
			ui::text_fit(shortcut.keys, x + 16, row_y + 12, key_w - 20, 14, ui::AQUA);
			ui::text_fit(shortcut.action, x + key_w + 22, row_y + 11, width - key_w - 44, 15, ui::FG);
		}
		ui::end_clip();
		ui::scrollbar(area, shortcuts_scroll, content);
	}
	else if (tab == 2)
	{
		if (ui::checkbox(x + 4, area.y + 8, "Move deleted files to the trash", &prefs::trash)) prefs::dirty = true;
		ui::text_fit(prefs::trash
			? "Delete moves items to the trash. Shift + Delete deletes permanently (asks first)."
			: "Delete removes items permanently after a confirmation. Nothing goes to the trash.", x + 4, area.y + 44, width - 8, 14, ui::FG4);
	}
	else
	{
		bool compact = box.height < 360;
		float bottom = box.y + box.height - (compact ? 70 : 94);
		if (!compact) ui::text_fit("Group patterns with commas. First matching rule wins. Executable only.", x, area.y, width, 14, ui::FG4);
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
			ui::input(101 + i * 2, { executable_x, row_y, executable_w, 36 }, &openers::rules[i].executable, "firefox-esr");
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
