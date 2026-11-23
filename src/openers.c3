module sms::openers;
import std::io, std::core::string;
import bmu::sys, bmu::txt, bmu::ui;
import sms::prefs;

const int MAX_RULES = 16;
const int MAX_DATA = 22000;
struct Rule
{
	char[256] pattern;
	char[1024] executable;
}
Rule[MAX_RULES] rules;
int count;
char[MAX_DATA] data;
char[120] error;
int[16] children;
int active_children;
extern fn CInt fnmatch(ZString pattern, ZString name, CInt flags) @cname("fnmatch");

fn String config_path() => txt::join(txt::view(&prefs::config_dir), "openers");

fn bool valid(String pattern, String executable)
{
	if (!pattern.len || !executable.len || pattern.len >= 256 || executable.len >= 1024) return false;
	foreach (ch : pattern) if (ch == '|' || ch == '\n' || ch == '\r' || ch == 0) return false;
	foreach (ch : executable) if (ch == '|' || ch == '\n' || ch == '\r' || ch == 0) return false;
	usz start;
	for (usz i = 0; i <= pattern.len; i++)
	{
		if (i < pattern.len && pattern[i] != ',') continue;
		if (!pattern[start:i - start].trim().len) return false;
		start = i + 1;
	}
	return true;
}

fn void load() => @pool()
{
	count = 0;
	txt::set(&error, "");
	if (txt::empty(&prefs::config_dir)) { txt::set(&error, "Config directory path is too long"); return; }
	String path = config_path();
	if (!sys::exists(path))
	{
		count = 1;
		txt::set(&rules[0].pattern, "*.pdf");
		txt::set(&rules[0].executable, "firefox-esr");
		if (!save()) txt::set(&error, "Could not create default openers config");
		return;
	}
	File? f = file::open(path, "rb");
	if (catch f) { txt::set(&error, "Cannot read openers config"); return; }
	defer (void)f.close();
	long? size = f.size();
	if (catch size) { txt::set(&error, "Cannot read openers config size"); return; }
	if (size < 0 || size >= MAX_DATA) { txt::set(&error, "Openers config exceeds 21999 bytes"); return; }
	sz? got = f.read(data[:(usz)size]);
	if (catch got) { txt::set(&error, "Cannot read openers config"); return; }
	if (got != size) { txt::set(&error, "Incomplete openers config read"); return; }
	Rule[MAX_RULES] parsed;
	int n;
	foreach (raw : ((String)data[:(usz)got]).tsplit("\n"))
	{
		String line = raw.trim();
		if (!line.len || line.starts_with("#")) continue;
		sz? separator = line.index_of_char('|');
		if (catch separator) { txt::set(&error, "Invalid rule: expected pattern | executable"); return; }
		String pattern = line[:(usz)separator].trim();
		String executable = line[(usz)separator + 1..].trim();
		if (n == MAX_RULES || !valid(pattern, executable))
		{
			txt::set(&error, "Invalid rule or more than 16 rules (nothing loaded)");
			return;
		}
		txt::set(&parsed[n].pattern, pattern);
		txt::set(&parsed[n++].executable, executable);
	}
	rules = parsed;
	count = n;
}

fn bool save() => @pool()
{
	if (txt::empty(&prefs::config_dir)) return false;
	for (int i = 0; i < count; i++)
	{
		if (!valid(txt::view(&rules[i].pattern).trim(), txt::view(&rules[i].executable).trim()))
		{
			txt::set(&error, "Use non-empty comma-separated patterns and an executable; no | or newlines");
			return false;
		}
	}
	txt::set(&data, "# Comma-separated filename globs | executable. First matching rule wins; no shell.\n");
	for (int i = 0; i < count; i++)
	{
		txt::append(&data, txt::view(&rules[i].pattern).trim());
		txt::append(&data, " | ");
		txt::append(&data, txt::view(&rules[i].executable).trim());
		txt::append(&data, "\n");
	}
	String path = config_path();
	String temp = txt::join(txt::view(&prefs::config_dir), "openers.tmp");
	if (!sys::mkdirs(txt::view(&prefs::config_dir)) || !sys::write_file(temp, txt::view(&data)) || !sys::move(temp, path))
	{
		txt::set(&error, "Could not save openers config");
		return false;
	}
	txt::set(&error, "");
	return true;
}

// Commas separate alternatives; whitespace around each glob is ignored.
fn bool matches(String patterns, String name)
{
	char[256] filename;
	txt::set(&filename, name);
	usz start;
	for (usz i = 0; i <= patterns.len; i++)
	{
		if (i < patterns.len && patterns[i] != ',') continue;
		String part = patterns[start:i - start].trim();
		if (part.len && part.len < 256)
		{
			char[256] pattern;
			txt::set(&pattern, part);
			if (!fnmatch(txt::z(&pattern), txt::z(&filename), 0)) return true;
		}
		start = i + 1;
	}
	return false;
}

// Explicit activation only. Prepare arguments before fork; never invoke a shell or wait synchronously.
const int MAX_ARGS = 256; // files per opener process (more are split into further launches)

fn int rule_for(String name)
{
	for (int i = 0; i < count; i++) if (matches(txt::view(&rules[i].pattern), name)) return i;
	return -1;
}

<* Start `rule`'s executable with `files` as literal arguments (no shell). Arguments are prepared before fork. *>
fn bool spawn(int rule, ZString[] files) => @pool()
{
	int slot = -1;
	for (int i = 0; i < children.len; i++) if (!children[i]) { slot = i; break; }
	if (slot < 0) { ui::toast("All 16 opener process slots are busy", ui::RED); return false; }
	String exe = txt::view(&rules[rule].executable).trim();
	if (!exe.len) { ui::toast("This opener has no executable", ui::RED); return false; }
	ZString[] argv = mem::talloc_array(ZString, files.len + 2);
	argv[0] = exe.zstr_tcopy();
	foreach (i, f : files) argv[i + 1] = f;
	argv[files.len + 1] = null;
	int pid = sys::c_fork();
	if (pid < 0) { ui::toast("Could not launch file opener", ui::RED); return false; }
	if (pid == 0)
	{
		sys::c_execvpe(argv[0], &argv[0], sys::environ);
		sys::c_exit(127);
	}
	children[slot] = pid;
	active_children++;
	return true;
}

// Explicit activation only. Prepare arguments before fork; never invoke a shell or wait synchronously.
fn bool launch(String path) => @pool()
{
	int rule = rule_for(txt::basename(path));
	if (rule < 0) { ui::toast("No matching file opener. Configure one with Ctrl+K.", ui::RED); return false; }
	ZString[1] one = { path.zstr_tcopy() };
	return spawn(rule, &one);
}

<*
 Open several files of one folder: one process per matching rule with all its files as arguments
 (`viewer a.pdf b.pdf`), so single-instance programs get every file instead of racing each other.
 Returns false when no file matched a rule.
*>
fn bool launch_many(String dir, String[] names) => @pool()
{
	int[] rule_of = mem::talloc_array(int, names.len);
	int unmatched;
	foreach (i, n : names)
	{
		rule_of[i] = rule_for(n);
		if (rule_of[i] < 0) unmatched++;
	}
	bool started;
	ZString[] batch = mem::talloc_array(ZString, MAX_ARGS);
	for (int r = 0; r < count; r++)
	{
		int k;
		foreach (i, n : names)
		{
			if (rule_of[i] != r) continue;
			batch[k++] = txt::join(dir, n).zstr_tcopy();
			if (k == MAX_ARGS) { if (!spawn(r, batch[:k])) return started; started = true; k = 0; }
		}
		if (k) { if (!spawn(r, batch[:k])) return started; started = true; }
	}
	if (unmatched) ui::toast(string::tformat("No file opener for %d %s. Configure one with Ctrl+K.", unmatched, unmatched == 1 ? "file" : "files"), ui::RED);
	return started || unmatched > 0;
}

// Bounded non-blocking reaping; no filesystem work.
fn void poll()
{
	if (!active_children) return;
	for (int i = 0; i < children.len; i++)
	{
		if (!children[i]) continue;
		CInt status;
		int result = sys::c_waitpid(children[i], &status, sys::WNOHANG);
		if (result > 0)
		{
			children[i] = 0;
			active_children--;
			if (status != 0) ui::toast("File opener failed (check executable in Ctrl+K)", ui::RED);
		}
	}
}
