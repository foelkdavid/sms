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
// What each child is: an opener (any non-zero exit is reported), a terminal or an "Open with" target (their own exit
// status is the user's business; only 126/127 = no folder / no program count).
enum Kind : char { OPENER, TERMINAL, OPEN_WITH }
Kind[16] child_kind;
int active_children;
extern fn CInt fnmatch(ZString pattern, ZString name, CInt flags) @cname("fnmatch");

fn String config_path() => txt::join(txt::view(&prefs::config_dir), "openers");

const int MAX_COMMAND_ARGS = 32;

<*
 Split an opener command ("alacritty -e vim") into program + arguments without a shell: whitespace separates,
 "..." and '...' group (no expansion of any kind), backslash escapes the next character outside single quotes.
 Tokens are written NUL-terminated into `storage`; returns the token count, or -1 (unterminated quote, too many
 tokens, storage full, empty).
*>
fn int split_command(String cmd, char[] storage, ZString[] out)
{
	int n;
	usz k;
	usz i;
	while (true)
	{
		while (i < cmd.len && (cmd[i] == ' ' || cmd[i] == '\t')) i++;
		if (i >= cmd.len) break;
		if (n >= out.len) return -1;
		out[n++] = (ZString)&storage[k];
		char quote = 0;
		while (i < cmd.len)
		{
			char c = cmd[i];
			if (!quote && (c == ' ' || c == '\t')) break;
			i++;
			if (quote && c == quote) { quote = 0; continue; }
			if (!quote && (c == '"' || c == '\'')) { quote = c; continue; }
			if (c == '\\' && quote != '\'' && i < cmd.len) c = cmd[i++];
			if (k + 1 >= storage.len) return -1;
			storage[k++] = c;
		}
		if (quote) return -1;
		if (k + 1 >= storage.len) return -1;
		storage[k++] = 0;
	}
	return n ? n : -1;
}

<* The split command of the first rule matching `name` (files not added): token count, -1 = no rule, -2 = bad command. *>
fn int command_for(String name, char[] storage, ZString[] out)
{
	int rule = rule_for(name);
	if (rule < 0) return -1;
	int n = split_command(txt::view(&rules[rule].executable), storage, out);
	return n < 0 ? -2 : n;
}

fn bool valid(String pattern, String executable)
{
	if (!pattern.len || !executable.len || pattern.len >= 256 || executable.len >= 1024) return false;
	foreach (ch : pattern) if (ch == '|' || ch == '\n' || ch == '\r' || ch == 0) return false;
	foreach (ch : executable) if (ch == '|' || ch == '\n' || ch == '\r' || ch == 0) return false;
	char[1024] storage;
	ZString[MAX_COMMAND_ARGS] tokens;
	if (split_command(executable, &storage, &tokens) < 0) return false;
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

<*
 Start the configured terminal (`prefs::terminal`, split like an opener command, no shell) with `dir` as its
 working directory. Everything is prepared before fork; the child only changes directory and execs.
*>
fn bool open_terminal(String dir) => @pool()
{
	if (txt::empty(&prefs::terminal)) { ui::toast("No terminal configured. Set one in Ctrl+K → General.", ui::RED); return false; }
	return run(txt::view(&prefs::terminal), {}, dir, TERMINAL);
}

<* Open `dir` in a new sms window: this binary again, detached (double fork; no opener slot, no zombie). *>
fn bool open_window(String dir) => @pool()
{
	ZString[4] argv = { "sms", "--dir", dir.zstr_tcopy(), null };
	int pid = sys::c_fork();
	if (pid < 0) { ui::toast("Could not open a new window", ui::RED); return false; }
	if (pid == 0)
	{
		sys::c_setsid();
		if (sys::c_fork() == 0)
		{
			sys::c_execvpe("/proc/self/exe", &argv, sys::environ);
			sys::c_exit(127);
		}
		sys::c_exit(0);
	}
	CInt status;
	sys::c_waitpid(pid, &status, 0);
	return true;
}

<*
 Start `command` (split without a shell) with `files` appended as literal arguments, in working directory `cwd`
 ("" = sms's own). Everything is prepared before fork; the child only changes directory and execs.
*>
fn bool run(String command, ZString[] files, String cwd, Kind kind) => @pool()
{
	int slot = -1;
	for (int i = 0; i < children.len; i++) if (!children[i]) { slot = i; break; }
	if (slot < 0) { ui::toast("All 16 opener process slots are busy", ui::RED); return false; }
	char[1024] storage;
	ZString[MAX_COMMAND_ARGS] tokens;
	int argc = split_command(command, &storage, &tokens);
	if (argc < 0) { ui::toast("The command is empty or has an unclosed quote", ui::RED); return false; }
	ZString[] argv = mem::talloc_array(ZString, (usz)argc + files.len + 1);
	for (int i = 0; i < argc; i++) argv[i] = tokens[i];
	foreach (usz i, f : files) argv[(usz)argc + i] = f;
	argv[(usz)argc + files.len] = null;
	ZString dir = cwd.len ? cwd.zstr_tcopy() : null;
	int pid = sys::c_fork();
	if (pid < 0) { ui::toast("Could not start the program", ui::RED); return false; }
	if (pid == 0)
	{
		if (dir && sys::c_chdir(dir) != 0) sys::c_exit(126);
		sys::c_execvpe(argv[0], &argv[0], sys::environ);
		sys::c_exit(127);
	}
	children[slot] = pid;
	child_kind[slot] = kind;
	active_children++;
	return true;
}

// Explicit activation only. Prepare arguments before fork; never invoke a shell or wait synchronously.
const int MAX_ARGS = 256; // files per opener process (more are split into further launches)

fn int rule_for(String name)
{
	for (int i = 0; i < count; i++) if (matches(txt::view(&rules[i].pattern), name)) return i;
	return -1;
}

<* Start `rule`'s executable with `files` as literal arguments (no shell). *>
fn bool spawn(int rule, ZString[] files) => run(txt::view(&rules[rule].executable), files, "", OPENER);

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
			int code = (status >> 8) & 0xff;
			bool exited = (status & 0x7f) == 0;
			if (child_kind[i] == TERMINAL)
			{
				if (exited && code == 127) ui::toast("Terminal command not found (Ctrl+K → General)", ui::RED);
				if (exited && code == 126) ui::toast("Could not enter the folder for the terminal", ui::RED);
			}
			else if (child_kind[i] == OPEN_WITH)
			{
				if (exited && code == 127) ui::toast("Open with: program not found (Ctrl+K → Open with)", ui::RED);
				if (exited && code == 126) ui::toast("Open with: could not enter the folder", ui::RED);
			}
			else if (status != 0) { ui::toast("File opener failed (check executable in Ctrl+K)", ui::RED); }
		}
	}
}
