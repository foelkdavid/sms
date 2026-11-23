module sms::complete;
import std::math, std::core::string;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys;
import sms::prefs;

// Folder completions for the path bar (Ctrl+L). The folder being typed into is listed once when it changes
// (bounded); each keystroke only filters that cached listing, never touches the disk.

const int MAX_LISTED = 2048;
const int SHOW = 8;
const float ROW = 32;

sys::Entry[MAX_LISTED] listing;
int listing_count;
char[4096] listed_dir;   // absolute folder of `listing`
char[4096] typed_dir;    // the folder part as typed ("~/", "/usr/", "" for relative names)
char[4096] last_text;    // text the matches were computed for
int[SHOW] hits;          // indices into listing
int hit_count;
int match_count;         // all matches (hits shows the first SHOW)
int sel = -1;            // highlighted suggestion; -1 = none
bool open;
bool computed;

fn void close()
{
	open = false;
	computed = false;
	sel = -1;
}

<* Recompute suggestions when `text` changed; lists a folder only when the folder part changed. *>
fn void update(String text, String cwd) => @pool()
{
	if (computed && text == txt::view(&last_text)) return;
	computed = true;
	txt::set(&last_text, text);
	sel = -1;
	hit_count = 0;
	match_count = 0;
	usz cut = 0;
	sz? slash = text.rindex_of_char('/');
	if (try slash) cut = (usz)slash + 1;
	String dir_part = text[:cut];
	String prefix = text[cut..];
	txt::set(&typed_dir, dir_part);
	// Resolve the folder part like navigate() does: "~", "~/x", absolute, or relative to the shown folder.
	String abs;
	if (dir_part.starts_with("~/")) { abs = txt::join(sys::home(), dir_part[2..]); }
	else if (text == "~") { abs = sys::home(); prefix = ""; txt::set(&typed_dir, "~/"); }
	else if (dir_part.starts_with("/")) { abs = dir_part; }
	else { abs = txt::join(cwd, dir_part); }
	if (abs != txt::view(&listed_dir))
	{
		txt::set(&listed_dir, abs);
		int n = sys::list_dir(abs, &listing, true);
		listing_count = 0;
		// list_dir puts folders first: keep only those.
		for (int i = 0; i < n && listing[i].dir; i++) listing_count++;
	}
	bool show_hidden = prefs::hidden || prefix.starts_with(".");
	for (int i = 0; i < listing_count; i++)
	{
		String name = txt::view(&listing[i].name);
		if (name[0] == '.' && !show_hidden) continue;
		if (!txt::istarts_with(name, prefix)) continue;
		if (hit_count < SHOW) hits[hit_count++] = i;
		match_count++;
	}
	open = hit_count > 0;
}

<* Suggestion i as the path to put into the bar ("/opt/"). Temp string. *>
fn String suggestion(int i) => string::tformat("%s%s/", txt::view(&typed_dir), txt::view(&listing[hits[i]].name));

<* Tab: extend to the longest common prefix of all matches; when that adds nothing, take the highlighted (or first) one. *>
fn void tab(char[] buf) => @pool()
{
	if (!open || !hit_count) return;
	String typed = txt::view(buf);
	String prefix = typed[txt::view(&typed_dir).len..];
	// Longest common prefix (case of the first match) over all matches, not only the shown ones.
	String first;
	usz common = 0;
	bool show_hidden = prefs::hidden || prefix.starts_with(".");
	for (int i = 0; i < listing_count; i++)
	{
		String name = txt::view(&listing[i].name);
		if (name[0] == '.' && !show_hidden) continue;
		if (!txt::istarts_with(name, prefix)) continue;
		if (!first.len) { first = name; common = name.len; continue; }
		usz k = 0;
		while (k < common && k < name.len && txt::lower(first[k]) == txt::lower(name[k])) k++;
		common = k;
	}
	if (match_count > 1 && common > prefix.len)
	{
		ui::input_replace(buf, txt::join(txt::view(&typed_dir), first[:common]));
		return;
	}
	ui::input_replace(buf, suggestion(sel >= 0 ? sel : 0));
}

fn void move(int step)
{
	if (!open || !hit_count) return;
	if (sel < 0) { sel = step > 0 ? 0 : hit_count - 1; return; }
	sel = math::clamp(sel + step, 0, hit_count - 1);
}

fn Rect area(Rect field) => { field.x, field.y + field.height + 4, field.width, (float)hit_count * ROW + 8 + (match_count > hit_count ? 22 : 0) };

<*
 Mouse on the suggestions, before the input and the rest of the frame: a click accepts a suggestion (the field keeps
 focus), and anything under the box stops reacting to the pointer. Returns true when a suggestion was taken.
*>
fn bool mouse(Rect field, char[] buf) => @pool()
{
	if (!open || !hit_count) return false;
	Rect box = area(field);
	if (!ui::point_in(rl::get_mouse_position(), box)) return false;
	for (int i = 0; i < hit_count; i++)
	{
		Rect row = { box.x + 4, box.y + 4 + (float)i * ROW, box.width - 8, ROW };
		if (ui::hover(row)) sel = i;
		if (ui::clicked(row)) { ui::input_replace(buf, suggestion(i)); return true; }
	}
	ui::consumed = true; // the box covers the list: no hover / clicks below it
	return false;
}

fn void draw(Rect field) => @pool()
{
	if (!open || !hit_count) return;
	Rect box = area(field);
	ui::panel(box, ui::BG_HARD, 6);
	ui::outline(box, ui::BG2, 6);
	for (int i = 0; i < hit_count; i++)
	{
		Rect row = { box.x + 4, box.y + 4 + (float)i * ROW, box.width - 8, ROW };
		if (i == sel) ui::panel(row, ui::BG2, 4);
		ui::text(ui::I_FOLDER, row.x + 10, row.y + 8, 15, ui::YELLOW);
		ui::text_tail(suggestion(i), row.x + 36, row.y + 8, row.width - 44, 15, ui::FG);
	}
	if (match_count > hit_count) ui::text(string::tformat("+%d more", match_count - hit_count), box.x + 40, box.y + box.height - 22, 13, ui::GRAY);
}
