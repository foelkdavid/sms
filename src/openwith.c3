module sms::openwith;
import std::io, std::core::string;
import bmu::sys, bmu::txt, bmu::ui;
import sms::prefs, sms::openers;

<*
 "Open with" targets: named commands offered in the right-click menus of files, folders and free list space
 (`name | command` lines in `sms/openwith`, none by default). The command is split like an opener rule (no shell);
 the chosen paths follow as literal arguments and the program runs in the folder (a file's folder, or the folder
 itself). The menu icon comes from the first command token whose program name is in ICONS, else the target name.
*>
const int MAX_TARGETS = 16;
const int MAX_DATA = 20000;
struct Target
{
	char[64] name;
	char[1024] command;
}
Target[MAX_TARGETS] targets;
String[MAX_TARGETS] icon; // per target, resolved on load/save (never per frame)
int count;
char[MAX_DATA] data;
char[120] error;

struct Icon
{
	String program;
	String glyph;
}
// Program name -> Nerd Font glyph (all in the embedded font: CodeNewRoman Nerd Font Propo, BMP codepoints only).
const Icon[*] ICONS = {
	{ "vim", "" }, { "gvim", "" }, { "vi", "" },
	{ "nvim", "" }, { "neovim", "" }, { "nvim-qt", "" }, { "neovide", "" },
	{ "emacs", "" }, { "emacsclient", "" },
	{ "nano", "" },
	{ "code", "" }, { "vscode", "" },
	{ "codium", "" }, { "vscodium", "" },
	{ "subl", "" }, { "sublime_text", "" },
	{ "idea", "" }, { "intellij-idea-community", "" },
	{ "firefox", "" }, { "firefox-esr", "" },
	{ "chromium", "" }, { "chrome", "" }, { "google-chrome", "" }, { "google-chrome-stable", "" },
	{ "gimp", "" },
	{ "inkscape", "" },
	{ "krita", "" },
	{ "blender", "" },
	{ "libreoffice", "" }, { "soffice", "" },
	{ "mpv", "" },
	{ "thunderbird", "" },
	{ "python", "" }, { "python3", "" },
	{ "git", "" },
};
// Baked into the font after ui::open (main): one codepoint per distinct glyph above.
const int[*] ICON_CODEPOINTS = { 0xE7C5, 0xF36F, 0xE632, 0xE838, 0xE8DA, 0xF372, 0xE7AA, 0xE7B5, 0xF269, 0xF268,
	0xF338, 0xF33B, 0xF33D, 0xE766, 0xF376, 0xF36E, 0xF370, 0xE73C, 0xE702 };

fn String config_path() => txt::join(txt::view(&prefs::config_dir), "openwith");

fn String glyph_for_program(String word)
{
	String base = word;
	sz? slash = word.rindex_of_char('/');
	if (try slash) base = word[(usz)slash + 1..];
	foreach (ic : ICONS) if (txt::ieq(base, ic.program)) return ic.glyph;
	return "";
}

<* Icon for a target: first command token naming a known program ("foot nvim" -> neovim), then the name. *>
fn String icon_for(String name, String command)
{
	char[1024] storage;
	ZString[openers::MAX_COMMAND_ARGS] tokens;
	int n = openers::split_command(command, &storage, &tokens);
	for (int i = 0; i < n; i++)
	{
		String g = glyph_for_program(tokens[i].str_view());
		if (g.len) return g;
	}
	foreach (word : name.tsplit(" "))
	{
		String g = glyph_for_program(word.trim());
		if (g.len) return g;
	}
	return ui::I_EXTERNAL;
}

fn void resolve_icons() => @pool()
{
	for (int i = 0; i < count; i++) icon[i] = icon_for(txt::view(&targets[i].name), txt::view(&targets[i].command));
}

fn bool valid(String name, String command)
{
	if (!name.len || !command.len || name.len >= 64 || command.len >= 1024) return false;
	foreach (ch : name) if (ch == '|' || ch == '\n' || ch == '\r' || ch == 0) return false;
	foreach (ch : command) if (ch == '|' || ch == '\n' || ch == '\r' || ch == 0) return false;
	char[1024] storage;
	ZString[openers::MAX_COMMAND_ARGS] tokens;
	return openers::split_command(command, &storage, &tokens) > 0;
}

<* One bounded read at startup; a missing file means no targets (nothing is created). *>
fn void load() => @pool()
{
	count = 0;
	txt::set(&error, "");
	if (txt::empty(&prefs::config_dir)) return;
	String path = config_path();
	if (!sys::exists(path)) return;
	File? f = file::open(path, "rb");
	if (catch f) { txt::set(&error, "Cannot read open-with config"); return; }
	defer (void)f.close();
	long? size = f.size();
	if (catch size) { txt::set(&error, "Cannot read open-with config size"); return; }
	if (size < 0 || size >= MAX_DATA) { txt::set(&error, "Open-with config exceeds 19999 bytes"); return; }
	sz? got = f.read(data[:(usz)size]);
	if (catch got) { txt::set(&error, "Cannot read open-with config"); return; }
	if (got != size) { txt::set(&error, "Incomplete open-with config read"); return; }
	Target[MAX_TARGETS] parsed;
	int n;
	foreach (raw : ((String)data[:(usz)got]).tsplit("\n"))
	{
		String line = raw.trim();
		if (!line.len || line.starts_with("#")) continue;
		sz? separator = line.index_of_char('|');
		if (catch separator) { txt::set(&error, "Invalid entry: expected name | command"); return; }
		String name = line[:(usz)separator].trim();
		String command = line[(usz)separator + 1..].trim();
		if (n == MAX_TARGETS || !valid(name, command))
		{
			txt::set(&error, "Invalid entry or more than 16 entries (nothing loaded)");
			return;
		}
		txt::set(&parsed[n].name, name);
		txt::set(&parsed[n++].command, command);
	}
	targets = parsed;
	count = n;
	resolve_icons();
}

fn bool save() => @pool()
{
	if (txt::empty(&prefs::config_dir)) return false;
	for (int i = 0; i < count; i++)
	{
		if (!valid(txt::view(&targets[i].name).trim(), txt::view(&targets[i].command).trim()))
		{
			txt::set(&error, "Every entry needs a name and a command; no | or newlines, quotes closed");
			return false;
		}
	}
	txt::set(&data, "# name | command. Shown in the right-click menus; the paths follow as arguments; no shell.\n");
	for (int i = 0; i < count; i++)
	{
		txt::append(&data, txt::view(&targets[i].name).trim());
		txt::append(&data, " | ");
		txt::append(&data, txt::view(&targets[i].command).trim());
		txt::append(&data, "\n");
	}
	String path = config_path();
	String temp = txt::join(txt::view(&prefs::config_dir), "openwith.tmp");
	if (!sys::mkdirs(txt::view(&prefs::config_dir)) || !sys::write_file(temp, txt::view(&data)) || !sys::move(temp, path))
	{
		txt::set(&error, "Could not save open-with config");
		return false;
	}
	txt::set(&error, "");
	resolve_icons();
	return true;
}

<* Open `names` of folder `dir` (none = the folder itself) with target `t`; runs in `dir`. *>
fn bool launch(int t, String dir, String[] names) => @pool()
{
	if (t < 0 || t >= count) return false;
	usz n = names.len ? names.len : 1;
	if (n > openers::MAX_ARGS) { ui::toast(string::tformat("Open with takes at most %d items", openers::MAX_ARGS), ui::RED); return false; }
	ZString[] paths = mem::talloc_array(ZString, (sz)n);
	if (!names.len) paths[0] = dir.zstr_tcopy();
	foreach (i, name : names) paths[i] = txt::join(dir, name).zstr_tcopy();
	return openers::run(txt::view(&targets[t].command), paths, dir, OPEN_WITH);
}

<* Menu items "Open with NAME" for every target (inside an open ui::menu); `dir`/`names` as for launch. *>
fn void menu_items(String dir, String[] names)
{
	if (!count) return;
	ui::menu_sep();
	for (int i = 0; i < count; i++)
	{
		@pool()
		{
			if (ui::menu_item(string::tformat("Open with %s", txt::view(&targets[i].name)), icon[i], "")) launch(i, dir, names);
		};
	}
}
