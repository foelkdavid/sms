module sms::prefs;
import std::io, std::core::string;
import bmu::sys, bmu::txt;

const int MAX_PLACES = 32;
const int DATA_SIZE = 140000;
struct Place
{
	char[4096] path;
}
Place[MAX_PLACES] places;
int place_count;
bool hidden;
bool sidebar = true;
int content_percent = 100;
int ui_percent; // 0 = monitor default until the user adjusts whole-UI zoom
bool dirty;
char[1024] config_dir;
char[DATA_SIZE] data;

// One bounded read at startup. Tests use a temporary XDG_CONFIG_HOME.
fn void load() => @pool()
{
	String base = sys::env("XDG_CONFIG_HOME");
	if (!base.starts_with("/")) base = txt::join(sys::home(), ".config");
	String folder = txt::join(base, "sms");
	if (folder.len >= config_dir.len - 16) return;
	txt::set(&config_dir, folder);
	File? f = file::open(txt::join(folder, "settings"), "rb");
	if (catch f) return;
	defer (void)f.close();
	long? size = f.size();
	if (catch size) return;
	if (size < 0 || size >= DATA_SIZE) return;
	sz? got = f.read(data[:(usz)size]);
	if (catch got) return;
	if (got != size) return;
	foreach (line : ((String)data[:(usz)got]).tsplit("\n"))
	{
		if (line.starts_with("hidden=")) hidden = line == "hidden=1";
		if (line.starts_with("sidebar=")) sidebar = line != "sidebar=0";
		if (line.starts_with("content_scale="))
		{
			if (try value = line[14..].to_int()) if (value >= 50 && value <= 250) content_percent = value;
		}
		if (line.starts_with("ui_scale="))
		{
			if (try value = line[9..].to_int()) if (value == 0 || (value >= 75 && value <= 300)) ui_percent = value;
		}
		if (line.starts_with("place=/") && place_count < MAX_PLACES && line.len - 6 < 4096)
		{
			txt::set(&places[place_count++].path, line[6..]);
		}
	}
}

// Write only on normal exit after a user change, using an atomic rename.
fn bool save() => @pool()
{
	if (!dirty) return true;
	String folder = txt::view(&config_dir);
	if (!folder.len || !sys::mkdirs(folder)) return false;
	txt::set(&data, hidden ? "hidden=1\n" : "hidden=0\n");
	txt::append(&data, sidebar ? "sidebar=1\n" : "sidebar=0\n");
	txt::append(&data, string::tformat("content_scale=%d\nui_scale=%d\n", content_percent, ui_percent));
	for (int i = 0; i < place_count; i++)
	{
		txt::append(&data, "place=");
		txt::append(&data, txt::view(&places[i].path));
		txt::append(&data, "\n");
	}
	String temp = txt::join(folder, "settings.tmp");
	if (!sys::write_file(temp, txt::view(&data))) return false;
	if (!sys::move(temp, txt::join(folder, "settings"))) return false;
	dirty = false;
	return true;
}

fn bool add(String path)
{
	if (place_count == MAX_PLACES || path.len >= 4096) return false;
	foreach (c : path) if (c == '\n' || c == '\r') return false;
	for (int i = 0; i < place_count; i++) if (txt::view(&places[i].path) == path) return true;
	txt::set(&places[place_count++].path, path);
	dirty = true;
	return true;
}

fn void remove(int index)
{
	for (int i = index; i + 1 < place_count; i++) places[i] = places[i + 1];
	place_count--;
	dirty = true;
}
