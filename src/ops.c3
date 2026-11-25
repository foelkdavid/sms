module sms::ops;
import std::math, std::core::string, libc;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::fileop, bmu::sys;
import sms::prefs, sms::openers;

// File operations: clipboard (Ctrl+C / Ctrl+X / Ctrl+V), drag moves, Del / Shift+Del, one background
// bmu::fileop job with a docked progress bar, conflict / delete / quit dialogs. All disk work runs on the
// job's worker; this module only polls it once per frame (one lock, no I/O).

const float PANEL_H = 84;
const float ITEM_ROW = 26;     // per-item rows of the expanded progress panel
const int ITEM_ROWS_MAX = 6;   // rows shown at once (the rest scroll)

// Bounded list of names inside one folder, heap storage reused between operations (no per-frame use).
struct Names
{
	char[4096] dir;
	char* data;
	usz len;
	usz cap;
	uint* offs;
	int count;
	int offs_cap;
}

fn bool Names.set(&self, String dir, String[] names)
{
	self.count = 0;
	self.len = 0;
	if (names.len > fileop::MAX_ITEMS || dir.len >= self.dir.len) return false;
	usz bytes;
	foreach (n : names) bytes += n.len + 1;
	if (bytes > self.cap)
	{
		char* data = libc::realloc(self.data, bytes);
		if (!data) return false;
		self.data = data;
		self.cap = bytes;
	}
	if ((int)names.len > self.offs_cap)
	{
		uint* offs = libc::realloc(self.offs, names.len * uint::size);
		if (!offs) return false;
		self.offs = offs;
		self.offs_cap = (int)names.len;
	}
	foreach (n : names)
	{
		self.offs[self.count++] = (uint)self.len;
		libc::memcpy(self.data + self.len, n.ptr, n.len);
		self.data[self.len + n.len] = 0;
		self.len += n.len + 1;
	}
	txt::set(&self.dir, dir);
	return true;
}

fn String Names.at(&self, int i) => ((ZString)(self.data + self.offs[i])).str_view();

<* Temp array of views (valid until the names change). *>
fn String[] Names.tview(&self)
{
	String[] out = mem::talloc_array(String, (usz)self.count);
	for (int i = 0; i < self.count; i++) out[i] = self.at(i);
	return out;
}

fn void Names.free(&self)
{
	libc::free(self.data);
	libc::free(self.offs);
	*self = {};
}

fileop::Job job;
fileop::Job counter;           // COUNT for the permanent-delete question (independent of `job`)
fileop::Progress counted;
fileop::Job sizer;             // background COUNT of the trash for the sidebar badge
bool size_dirty = true;
char[24] trash_size;           // "4.2 GB"; empty = unknown or empty trash
bool counting;
char[96] count_text;
int count_shown = -1;
ulong count_bytes_shown;
fileop::State count_state_shown;
fileop::Progress cur;          // snapshot of this frame
Names clip;
bool clip_cut;
bool clip_archive;             // clip.dir is an archive file; Ctrl+V extracts the names from folder clip_inner of it
char[4096] clip_inner;
// EXTRACT parameters for begin() (set by extract()).
char[4096] ext_inner;
bool ext_smart;
char[4096] open_after;         // a temporary copy to open with its opener once extracted
Names pending;                 // waiting for the delete confirmation
// The running request, kept for "Retry as administrator" after a permission error.
Names req;
fileop::Kind req_kind;
char[4096] req_dst;
bool req_fallback;
bool req_elevated;
bool admin_open;
bool admin_for_open;           // the dialog asks for a program as sudo (not a retry of a file operation)
// The program to run as sudo (Shift+right-click menus): command split like an opener, paths appended, run in sudo_cwd.
char[1024] sudo_command;
Names sudo_args;               // dir + names: the appended paths (count 0 = no arguments)
char[4096] sudo_cwd;
char[64] sudo_title;
fileop::SudoRun[4] sudo_runs;  // programs started as root (each drained/reaped by its own thread)
bool admin_delete;             // TRASH failed: the retry deletes permanently as root (root's trash is not yours)
char[256] admin_pw;            // wiped on submit / cancel / close
char[512] admin_error;
const int ID_ADMIN_PW = 50;
bool confirm_open;
// New folder / new file (Ctrl+N, Ctrl+Shift+N, right-click): one name dialog, created in new_dir on the UI thread (one syscall).
bool new_open;
bool new_folder;
char[256] new_name;
char[4096] new_dir;
char[160] new_error;
char[256] created;             // the item just created, for the list to select after its reload ("" = none)
const int ID_NEW_NAME = 51;
bool pending_empty;             // the confirmation empties the whole trash
bool pending_fallback;         // TRASH with permanent fallback for items on other drives
int pending_untrashable;
bool apply_all;
bool refresh;                  // the folder listing may have changed
// Running job (for texts and the finish toast).
fileop::Kind job_kind;
int job_items;
bool job_clears_clip;
char[256] job_target;
double job_started;
char[160] title;
char[160] detail;
double sample_time;            // last detail-text refresh
double last_poll;
double active_time;            // seconds spent transferring (no scanning, no conflict dialog)
float shown_frac;              // drawn bar fill, eased toward the real fraction
ulong sample_bytes;            // bytes_done / active_time at the last detail refresh
double sample_active;
double recent_speed;           // bytes / s over the last few seconds (smoothed), 0 = none yet
double shown_eta;              // seconds left as displayed: counts down, nudged toward the estimate (-1 = none yet)
double eta_active;             // active_time when shown_eta was last updated
bool show_items;               // the progress panel lists each item (toggled by a click on it; kept for the session)
float items_scroll;
bool items_follow;             // keep the active item in view until the user scrolls
fileop::ItemProgress[16] item_rows; // visible rows only (one item_status call per frame)

fn bool busy() => job.busy();
fn bool modal() => confirm_open || admin_open || new_open || ui::close_requested || (job.busy() && cur.state == CONFLICT);
fn bool has_clip() => clip.count > 0;
<* Entry names cut to the clipboard are drawn dimmed while their folder is shown. *>
fn bool is_cut(String dir) => clip_cut && clip.count > 0 && txt::view(&clip.dir) == dir;

<* Ask for the name of a new folder (or empty file) in `dir`. *>
fn void ask_new(String dir, bool folder)
{
	txt::set(&new_dir, dir);
	new_folder = folder;
	new_name[0] = 0;
	new_error[0] = 0;
	new_open = true;
	ui::focus_on(ID_NEW_NAME, &new_name);
}

<* Create the asked-for item; false (with new_error set) keeps the dialog open. *>
fn bool create_new() => @pool()
{
	String name = txt::view(&new_name).trim();
	if (!name.len) { txt::set(&new_error, "Enter a name"); return false; }
	if (name == "." || name == ".." || name.contains("/")) { txt::set(&new_error, "A name can't be . or .. or contain /"); return false; }
	ZString path = txt::join(txt::view(&new_dir), name).zstr_tcopy();
	bool ok;
	if (new_folder) { ok = sys::c_mkdir(path, 0o777) == 0; }
	else
	{
		CInt fd = sys::c_open(path, sys::O_WRONLY | sys::O_CREAT | O_EXCL, 0o666);
		ok = fd >= 0;
		if (ok) sys::c_close(fd);
	}
	if (!ok)
	{
		int e = (int)libc::errno();
		txt::set(&new_error, e == 17 ? "Something with this name already exists" : e == 13 || e == 1 ? "Permission denied" : e == 30 ? "Read-only file system" : "Could not create it");
		return false;
	}
	txt::set(&created, name);
	refresh = true;
	return true;
}

const CInt O_EXCL = 0x80;

fn bool take_refresh()
{
	bool r = refresh;
	refresh = false;
	return r;
}

fn void close()
{
	job.close();
	counter.close();
	ui::wipe(&admin_pw);
	req.free();
	sizer.close();
	clip.free();
	pending.free();
	sudo_args.free();
}

fn String plural(int n, String one, String many) => n == 1 ? one : many;

fn void size_text(char[] out, ulong b) => @pool()
{
	if (b < 1000) { txt::set(out, string::tformat("%d B", b)); return; }
	double v = (double)b;
	String[4] units = { "kB", "MB", "GB", "TB" };
	int u = -1;
	while (v >= 1000 && u < 3) { v /= 1000; u++; }
	txt::set(out, v < 10 ? string::tformat("%.1f %s", v, units[u]) : string::tformat("%d %s", (int)(v + 0.5), units[u]));
}

fn void time_text(char[] out, double s) => @pool()
{
	long t = (long)(s + 0.5);
	if (t < 60) { txt::set(out, string::tformat("%d s", t)); return; }
	if (t < 3600) { txt::set(out, string::tformat("%d min", (t + 30) / 60)); return; }
	txt::set(out, string::tformat("%d h %d min", t / 3600, (t % 3600) / 60));
}

fn bool begin(fileop::Kind kind, String src_dir, String[] names, String dst_dir = "", bool fallback = false, char[] password = {}) => @pool()
{
	if (job.busy()) { ui::toast("Wait for the current file operation to finish", ui::RED); return false; }
	bool elevated = password.ptr != null;
	bool ok;
	if (kind == EXTRACT) { ok = job.extract(src_dir, txt::view(&ext_inner), names, dst_dir, ext_smart); }
	else if (elevated) { ok = job.start_elevated(kind, src_dir, names, dst_dir, password, fallback); }
	else { ok = job.start(kind, src_dir, names, dst_dir, fallback); }
	if (!ok) { ui::toast("Could not start the file operation", ui::RED); return false; }
	// Remember the request for a retry as administrator (names may point into the listing).
	if (!elevated) req.set(src_dir, names);
	req_kind = kind;
	txt::set(&req_dst, dst_dir);
	req_fallback = fallback;
	req_elevated = elevated;
	job_kind = kind;
	job_items = (int)names.len;
	job_clears_clip = false;
	txt::set(&job_target, dst_dir == "/" ? "/" : txt::basename(dst_dir));
	job_started = ui::now;
	sample_time = ui::now;
	last_poll = ui::now;
	active_time = 0;
	shown_frac = 0;
	sample_bytes = 0;
	sample_active = 0;
	recent_speed = 0;
	shown_eta = -1;
	items_scroll = 0;
	items_follow = true;
	apply_all = false;
	if (kind != EXTRACT) open_after[0] = 0;
	String what = names.len == 1 ? string::tformat("\"%s\"", names[0]) : string::tformat("%d items", names.len);
	if (kind == EXTRACT && !names.len) { what = string::tformat("\"%s\"", txt::basename(src_dir)); job_items = 1; }
	switch (kind)
	{
		case COPY: txt::set(&title, string::tformat("Copying %s to %s", what, txt::view(&job_target)));
		case MOVE: txt::set(&title, string::tformat("Moving %s to %s", what, txt::view(&job_target)));
		case TRASH: txt::set(&title, string::tformat("Moving %s to the trash", what));
		case DELETE: txt::set(&title, string::tformat("Deleting %s", what));
		case COUNT: txt::set(&title, string::tformat("Counting %s", what));
		case RESTORE: txt::set(&title, string::tformat("Restoring %s", what));
		case EXTRACT: txt::set(&title, string::tformat(open_after[0] ? "Extracting %s to open it" : "Extracting %s to %s", what, txt::view(&job_target)));
	}
	if (elevated) txt::append(&title, " as sudo");
	txt::set(&detail, "Preparing…");
	job.status(&cur);
	return true;
}

<* Move trashed items (names in the trash's files/ folder) back to where they were deleted from. *>
fn void restore(String trash_files, String[] names)
{
	if (names.len) begin(RESTORE, trash_files, names);
}

<*
 Extract `names` (direct children of folder `inner` of archive `archive_path`; none = all of it) into `dst`.
 `smart`: several top-level items go into a folder named after the archive. With `open_path`, the file is
 opened with its opener once extracted (a temporary copy) instead of a "done" toast.
*>
fn void extract(String archive_path, String inner, String[] names, String dst, bool smart, String open_path = "")
{
	if (job.busy()) { ui::toast("Wait for the current file operation to finish", ui::RED); return; }
	txt::set(&ext_inner, inner);
	ext_smart = smart;
	txt::set(&open_after, open_path);
	if (!begin(EXTRACT, archive_path, names, dst)) open_after[0] = 0;
}

// The system clipboard carries copied files between sms windows and other file managers
// (x-special/gnome-copied-files, text/uri-list, plain paths). The internal clip is current while sms still owns
// the clipboard (ui::clipboard_owned: no IPC). The system clipboard is read only on Ctrl+V of someone else's copy:
// a read waits on the owning app, so never on focus or per frame.

<* "file:///dir/a\r\n…" for names in dir (temp). *>
fn String uri_list(String dir, String[] names)
{
	DString d;
	d.tinit();
	foreach (n : names) { d.append(txt::file_uri(txt::join(dir, n))); d.append("\r\n"); }
	return d.str_view();
}

<* What the system clipboard holds as files: gnome-copied-files text, else a plain uri-list (temp, "" = none). *>
fn String system_files(bool* cut)
{
	String g = ui::clipboard_get_data("x-special/gnome-copied-files");
	if (g.len)
	{
		*cut = g.starts_with("cut\n") || g.starts_with("cut\r");
		return g;
	}
	*cut = false;
	String u = ui::clipboard_get_data("text/uri-list");
	return u.contains("file://") ? u : "";
}

fn void publish_clipboard(String dir, String[] names, bool cut) => @pool()
{
	String list = uri_list(dir, names);
	DString g;
	g.tinit();
	g.append(cut ? "cut" : "copy");
	DString plain;
	plain.tinit();
	foreach (i, n : names)
	{
		g.append("\n");
		g.append(txt::file_uri(txt::join(dir, n)));
		if (i) plain.append("\n");
		plain.append(txt::join(dir, n));
	}
	ui::clipboard_set_data({ "x-special/gnome-copied-files", "text/uri-list", "text/plain;charset=utf-8" }, { g.str_view(), list, plain.str_view() });
}

<* The window got focus: when another window or app replaced the clipboard, forget the internal clip (and its
   dimmed cut entries). Returns true when it was dropped. *>
fn bool sync_clipboard()
{
	if (!clip.count || ui::clipboard_owned()) return false;
	clip.free();
	clip_cut = false;
	clip_archive = false;
	return true;
}

fn void set_clipboard(String dir, String[] names, bool cut) => @pool()
{
	if (!names.len) return;
	if (!clip.set(dir, names)) { ui::toast("Too many items for the clipboard", ui::RED); return; }
	publish_clipboard(dir, names, cut);
	clip_cut = cut;
	clip_archive = false;
	ui::toast(string::tformat("%s %d %s", cut ? "Cut" : "Copied", names.len, plural((int)names.len, "item", "items")));
}

<* Ctrl+C inside an archive: Ctrl+V in a folder extracts these entries there. *>
fn void set_archive_clipboard(String archive_path, String inner, String[] names) => @pool()
{
	if (!names.len) return;
	if (!clip.set(archive_path, names)) { ui::toast("Too many items for the clipboard", ui::RED); return; }
	DString plain;   // entry paths as text, so the clipboard is ours (and pasting into a text field gives them)
	plain.tinit();
	foreach (i, n : names)
	{
		if (i) plain.append("\n");
		plain.append(txt::join(txt::join(archive_path, inner), n));
	}
	ui::clipboard_set_data({ "text/plain;charset=utf-8" }, { plain.str_view() });
	clip_cut = false;
	clip_archive = true;
	txt::set(&clip_inner, inner);
	ui::toast(string::tformat("Copied %d %s from the archive", names.len, plural((int)names.len, "item", "items")));
}

<* Ctrl+V: the files on the system clipboard (from another sms window or file manager), or sms's own clip while
   it is still the current one. Returns false when there is nothing to paste. *>
fn bool paste(String dst) => @pool()
{
	if (!clip.count || !ui::clipboard_owned())
	{
		bool cut;
		String sys_files = system_files(&cut);
		if (!sys_files.len) return false;
		paste_system(sys_files, cut, dst);
		return true;
	}
	paste_own(dst);
	return true;
}

<* Paste files listed as URIs (one source folder, like a drop). A cut is moved and then cleared from the clipboard. *>
fn void paste_system(String list, bool cut, String dst) => @pool()
{
	String from = "";
	String[] names = mem::talloc_array(String, 4096);
	int n;
	foreach (line : list.tsplit("\n"))
	{
		String p = txt::uri_path(line.trim());
		if (!p.len) continue;
		if (!from.len) from = txt::dirname(p).tcopy();
		if (txt::dirname(p) != from) { ui::toast("Paste items from one folder at a time", ui::RED); return; }
		if (n >= 4096) { ui::toast("Too many items for the clipboard", ui::RED); return; }
		names[n++] = txt::basename(p).tcopy();
	}
	if (!n) return;
	char[4096] real;
	sys::realpath(&real, from);
	if (cut && txt::view(&real) == dst) return; // moving into the same folder changes nothing
	if (begin(cut ? MOVE : COPY, txt::view(&real), names[:n], dst) && cut)
	{
		ui::clipboard_set_data({ "text/plain;charset=utf-8" }, { "" });   // a cut is pasted once
		clip.free();   // this "" is ours now: no older internal clip may count as current
		clip_cut = false;
		clip_archive = false;
	}
}

fn void paste_own(String dst) => @pool()
{
	if (clip_archive) { extract(txt::view(&clip.dir), txt::view(&clip_inner), clip.tview(), dst, false); return; }
	if (clip_cut && txt::view(&clip.dir) == dst) return; // moving into the same folder changes nothing
	if (begin(clip_cut ? MOVE : COPY, txt::view(&clip.dir), clip.tview(), dst)) job_clears_clip = clip_cut;
}

<* Drag & drop: move (or copy with Ctrl) names from src_dir into dst. *>
fn void transfer(String src_dir, String[] names, String dst, bool copy)
{
	if (!names.len || (!copy && src_dir == dst)) return;
	begin(copy ? COPY : MOVE, src_dir, names, dst);
}

<* Del (permanent = Shift+Del or trash disabled in settings). Stats each item once, only on the key press. *>
fn void remove(String dir, String[] names, bool permanent) => @pool()
{
	if (!names.len) return;
	if (job.busy()) { ui::toast("Wait for the current file operation to finish", ui::RED); return; }
	if (!permanent && prefs::trash)
	{
		int untrashable;
		foreach (n : names) if (!fileop::can_trash(txt::join(dir, n))) untrashable++;
		if (!untrashable) { begin(TRASH, dir, names); return; }
		pending_untrashable = untrashable;
		pending_fallback = true;
	}
	else
	{
		pending_untrashable = 0;
		pending_fallback = false;
	}
	if (!pending.set(dir, names)) { ui::toast("Too many items", ui::RED); return; }
	pending_empty = false;
	confirm_open = true;
	// Count in the background: the dialog opens at once and fills in "N items, X GB" as the scan runs.
	counter.close();
	counting = !pending_fallback && counter.start(COUNT, dir, names);
	counted = {};
	count_shown = -1;
	txt::set(&count_text, counting ? "Counting…" : "");
}

<* Empty the trash: everything in `<trash>/files` (one listing, on this explicit action), after the confirmation. *>
fn void empty_trash(String files_dir) => @pool()
{
	if (job.busy()) { ui::toast("Wait for the current file operation to finish", ui::RED); return; }
	sys::Entry[] found = mem::talloc_array(sys::Entry, fileop::MAX_ITEMS);
	int n = sys::list_dir(files_dir, found, true);
	if (n <= 0) { ui::toast("The trash is already empty"); return; }
	if (n == fileop::MAX_ITEMS) ui::toast(string::tformat("The trash holds more than %d items: empty it again afterwards", fileop::MAX_ITEMS), ui::YELLOW);
	String[] names = mem::talloc_array(String, (usz)n);
	for (int i = 0; i < n; i++) names[i] = txt::view(&found[i].name);
	remove(files_dir, names, true);
	pending_empty = confirm_open;
}

<* Once per frame, before input: progress snapshot, finish handling, close guard. *>
fn void poll() => @pool()
{
	poll_sudo();
	fileop::Progress done;
	if (job.finished(&done))
	{
		cur = done;
		refresh = !(job_kind == EXTRACT && open_after[0]); // a temporary copy changes no shown folder
		size_dirty = true;
		finished(&done);
	}
	else if (job.busy())
	{
		bool was_removing = cur.remove_total > 0;
		job.status(&cur);
		if (cur.remove_total > 0 && !was_removing) { shown_frac = 0; sample_time = 0; } // new step: bar restarts, text now
		double dt = math::min(ui::now - last_poll, 0.25);
		if (cur.state != SCANNING && cur.state != CONFLICT) active_time += dt;
		// Ease the bar toward the real fraction (~0.3 s), never backwards: flushes arrive in steps.
		float target = math::max(shown_frac, progress_frac());
		shown_frac += (target - shown_frac) * (float)math::min(1.0, dt * 8);
		if (ui::now - sample_time >= 0.5) update_detail();
	}
	last_poll = ui::now;
	ui::hold_close = job.busy();
	if (ui::close_requested && !job.busy()) ui::quit = true;
}

fn void finished(fileop::Progress* p) => @pool()
{
	String what = string::tformat("%d %s", job_items, plural(job_items, "item", "items"));
	String skipped = p.skipped ? string::tformat(" (%d skipped)", p.skipped) : "";
	switch (p.state)
	{
		case DONE:
			if (job_clears_clip) { clip.count = 0; clip_cut = false; }
			switch (job_kind)
			{
				case COPY: ui::toast(string::tformat("Copied %s%s", what, skipped), ui::GREEN);
				case MOVE: ui::toast(string::tformat("Moved %s%s", what, skipped), ui::GREEN);
				case TRASH: ui::toast(string::tformat("Moved %s to the trash", what), ui::GREEN);
				case DELETE: ui::toast(string::tformat("Deleted %s", what), ui::GREEN);
				case RESTORE: ui::toast(string::tformat("Restored %s%s", what, skipped), ui::GREEN);
				case EXTRACT:
					if (open_after[0])
					{
						if (openers::launch(txt::view(&open_after))) ui::toast("Opened a temporary copy (deleted when sms closes)");
					}
					else { ui::toast(string::tformat("Extracted %s%s", what, skipped), ui::GREEN); }
				case COUNT: break;
			}
		case CANCELLED:
			ui::toast(job_kind == COPY || job_kind == MOVE || job_kind == EXTRACT ? "Cancelled: nothing was changed" : "Cancelled", ui::YELLOW);
		default:
			// Permission denied: offer the same operation as administrator (not for restore / sizing).
			bool denied = p.err == 13 || p.err == 1;
			bool wrong_pw = req_elevated && txt::view(&p.error) == "Wrong password";
			if ((denied && !req_elevated && job_kind != RESTORE && job_kind != COUNT && job_kind != EXTRACT) || wrong_pw)
			{
				admin_delete = req_kind == TRASH || req_kind == DELETE;
				admin_for_open = false;
				if (!wrong_pw) { txt::set(&admin_error, txt::empty(&p.error) ? "Permission denied" : txt::view(&p.error)); }
				else { txt::set(&admin_error, "Wrong password. Try again."); }
				ui::wipe(&admin_pw);
				admin_open = true;
				ui::focus = ID_ADMIN_PW;
				return;
			}
			ui::toast(txt::empty(&p.error) ? "The file operation failed" : txt::view(&p.error), ui::RED);
	}
}

<*
 Shift+right-click menus: ask for the password, then run `command` (split like an opener, no shell) as root in
 `cwd` with `dir`/`names` appended as paths (none = no arguments). `what` describes it in the dialog.
*>
fn void ask_sudo(String title, String what, String command, String cwd, String dir, String[] names) => @pool()
{
	char[1024] storage;
	ZString[openers::MAX_COMMAND_ARGS] cmd;
	if (openers::split_command(command, &storage, &cmd) < 0) { ui::toast("The command is empty or has an unclosed quote", ui::RED); return; }
	if (names.len > openers::MAX_ARGS || !sudo_args.set(dir, names)) { ui::toast(string::tformat("Open as sudo takes at most %d items", openers::MAX_ARGS), ui::RED); return; }
	txt::set(&sudo_command, command);
	txt::set(&sudo_cwd, cwd);
	txt::set(&sudo_title, title);
	txt::set(&admin_error, string::tformat("%s: %s", what, command));
	admin_for_open = true;
	admin_delete = false;
	ui::wipe(&admin_pw);
	admin_open = true;
	ui::focus = ID_ADMIN_PW;
}

<* Open as sudo: the file's opener command as root. *>
fn void ask_open_as_sudo(String path) => @pool()
{
	int rule = openers::rule_for(txt::basename(path));
	if (rule < 0) { ui::toast("No matching file opener. Configure one with Ctrl+K.", ui::RED); return; }
	String[1] one = { txt::basename(path) };
	ask_sudo("Open as sudo", txt::basename(path), txt::view(&openers::rules[rule].executable), txt::dirname(path), txt::dirname(path), &one);
}

fn void open_as_sudo() => @pool()
{
	char[1024] storage;
	ZString[openers::MAX_COMMAND_ARGS] cmd;
	int n = openers::split_command(txt::view(&sudo_command), &storage, &cmd);
	if (n < 0) { ui::wipe(&admin_pw); return; }
	String[] argv = mem::talloc_array(String, (usz)n + (usz)sudo_args.count);
	for (int i = 0; i < n; i++) argv[i] = cmd[i].str_view();
	for (int i = 0; i < sudo_args.count; i++) argv[n + i] = txt::join(txt::view(&sudo_args.dir), sudo_args.at(i));
	fileop::SudoRun* free_run;
	foreach (&r : sudo_runs) if (!r.started) { free_run = r; break; }
	if (!free_run) { ui::toast("Too many programs running as sudo", ui::RED); }
	else if (!free_run.start(argv, &admin_pw, true, txt::view(&sudo_cwd))) { ui::toast("Could not start sudo", ui::RED); }
	ui::wipe(&admin_pw);
}

<* Once per frame: a lock + copy per running sudo program; a wrong password asks again. *>
fn void poll_sudo()
{
	foreach (&r : sudo_runs)
	{
		if (!r.started) continue;
		fileop::SudoState st = r.poll();
		if (st != FAILED) continue;
		if (txt::view(&r.error) == "Wrong password" && !admin_open)
		{
			txt::set(&admin_error, "Wrong password. Try again.");
			admin_for_open = true;
			admin_delete = false;
			ui::wipe(&admin_pw);
			admin_open = true;
			ui::focus = ID_ADMIN_PW;
		}
		else
		{
			ui::toast(txt::view(&r.error), ui::RED);
		}
	}
}

<* Run the remembered request again as root (sudo asks for this one operation only). *>
fn void retry_as_admin() => @pool()
{
	// Trash as root would fill root's trash: a denied trash becomes a permanent delete (the dialog says so).
	fileop::Kind kind = req_kind == TRASH ? DELETE : req_kind;
	bool clears = job_clears_clip;
	begin(kind, txt::view(&req.dir), req.tview(), txt::view(&req_dst), false, &admin_pw);
	job_clears_clip = clears;
	ui::wipe(&admin_pw);
}

<* Trash size for the sidebar: one COUNT of `<trash>/files` when dirty, never per-frame I/O. *>
fn void poll_trash_size(String trash_root)
{
	fileop::Progress p;
	if (sizer.finished(&p))
	{
		// files_total counts the files/ folder itself: 1 = empty trash.
		if (p.state == DONE && p.files_total > 1) { size_text(&trash_size, p.bytes_total); }
		else if (p.state == DONE || p.state == FAILED) { trash_size[0] = 0; }
	}
	if (size_dirty && !sizer.busy())
	{
		size_dirty = false;
		String[1] files = { "files" };
		if (!sizer.start(COUNT, trash_root, &files)) trash_size[0] = 0;
	}
}

fn void group_digits(char[] out, long n) => @pool()
{
	String raw = string::tformat("%d", n);
	char[32] tmp;
	usz k;
	foreach (i, c : raw)
	{
		if (i > 0 && (raw.len - i) % 3 == 0) tmp[k++] = ',';
		tmp[k++] = c;
	}
	txt::set(out, (String)tmp[:k]);
}

<* Poll the COUNT job; reformat the text only when the numbers changed. *>
fn void update_count() => @pool()
{
	if (!counting) return;
	if (counter.finished(&counted)) { counting = false; }
	else { counter.status(&counted); }
	if (counted.files_total == count_shown && counted.bytes_total == count_bytes_shown && counted.state == count_state_shown) return;
	count_shown = counted.files_total;
	count_bytes_shown = counted.bytes_total;
	count_state_shown = counted.state;
	char[32] n, size;
	group_digits(&n, counted.files_total);
	size_text(&size, counted.bytes_total);
	String items = counted.files_total == 1 ? "item" : "items";
	switch (counted.state)
	{
		case DONE: txt::set(&count_text, string::tformat("%s %s · %s in total", txt::view(&n), items, txt::view(&size)));
		case FAILED: txt::set(&count_text, string::tformat("At least %s %s · %s (some unreadable)", txt::view(&n), items, txt::view(&size)));
		default: txt::set(&count_text, string::tformat("Counting… %s %s · %s", txt::view(&n), items, txt::view(&size)));
	}
}

<* Real progress 0..1 of the running job: bytes when known, else files. *>
fn float progress_frac()
{
	if (cur.remove_total > 0) return math::min(1.0f, (float)cur.removed / (float)cur.remove_total);
	if (cur.state == FINISHING) return 1;
	if (cur.bytes_total > 0) return math::min(1.0f, (float)cur.bytes_done / (float)cur.bytes_total);
	if (cur.files_total > 0) return math::min(1.0f, (float)cur.files_done / (float)cur.files_total);
	return 0;
}

<* Speed and ETA mostly from the whole run so far (average), with a little recent speed blended in: calm, yet it
   follows a lasting change (small files, then big ones). *>
fn void update_detail() => @pool()
{
	sample_time = ui::now;
	double da = active_time - sample_active;
	if (da > 0.2 && cur.bytes_done >= sample_bytes)
	{
		double now_speed = (double)(cur.bytes_done - sample_bytes) / da;
		recent_speed = recent_speed <= 0 ? now_speed : recent_speed * 0.8 + now_speed * 0.2;
		sample_bytes = cur.bytes_done;
		sample_active = active_time;
	}
	char[32] a, b, c, d;
	switch (cur.state)
	{
		case SCANNING:
		case CONFLICT:
			size_text(&a, cur.bytes_total);
			txt::set(&detail, string::tformat("Preparing… %d files, %s", cur.files_total, txt::view(&a)));
		case FINISHING:
			if (cur.remove_total > 0)
			{
				group_digits(&a, cur.removed);
				group_digits(&b, cur.remove_total);
				txt::set(&detail, string::tformat("Removing originals… %s of %s", txt::view(&a), txt::view(&b)));
				break;
			}
			txt::set(&detail, cur.can_cancel ? "Finishing…" : txt::view(&cur.current) == "Undoing" ? "Undoing changes…" : "Finishing…");
		default:
			if (cur.bytes_total > 0)
			{
				size_text(&a, cur.bytes_done);
				size_text(&b, cur.bytes_total);
				double f = (double)cur.bytes_done / (double)cur.bytes_total;
				if (active_time < 1.5 || f < 0.005)
				{
					txt::set(&detail, string::tformat("%s of %s · estimating…", txt::view(&a), txt::view(&b)));
				}
				else
				{
					double avg = (double)cur.bytes_done / active_time;
					double rate = recent_speed > 0 ? avg * 0.85 + recent_speed * 0.15 : avg;
					size_text(&c, (ulong)rate);
					if (rate > 1)
					{
						// Count down by the time passed, then move a fifth of the way to the new estimate.
						double eta = (double)(cur.bytes_total - cur.bytes_done) / rate;
						shown_eta = shown_eta < 0 ? eta : math::max(0.0, shown_eta - (active_time - eta_active)) * 0.8 + eta * 0.2;
						eta_active = active_time;
						time_text(&d, shown_eta);
					}
					else { txt::set(&d, "—"); }
					txt::set(&detail, string::tformat("%s of %s · %s/s · %s left", txt::view(&a), txt::view(&b), txt::view(&c), txt::view(&d)));
				}
			}
			else
			{
				txt::set(&detail, string::tformat("%d of %d", cur.files_done, math::max(cur.files_total, cur.files_done)));
			}
	}
}

<* Height of the docked progress bar this frame (0 = hidden). Instant jobs never flash it. *>
fn float panel_height() => job.busy() && (ui::now - job_started > 0.25 || cur.state == CONFLICT) ? PANEL_H + items_height() : 0;

<* The panel can list its items: more than one, tracked by bmu (not archives, sizing or elevated jobs). *>
fn bool has_items() => job.item_count() > 1;

<* Height of the item rows under the bar (0 = collapsed): at most ITEM_ROWS_MAX rows and about a third of the window. *>
fn float items_height()
{
	if (!show_items || !has_items()) return 0;
	float rows = (float)math::min(job.item_count(), ITEM_ROWS_MAX);
	float room = math::max(ITEM_ROW * 2, ui::sh() * 0.35f - PANEL_H);
	return math::min(rows * ITEM_ROW, room) + 8;
}

<* Docked progress bar (layer 0) below the file list. *>
fn void draw_panel(Rect r)
{
	if (r.height <= 0) return;
	ui::panel(r, ui::BG_HARD, 6);
	ui::outline(r, ui::BG2, 6);
	float x = r.x + 14;
	float w = r.width - 28;
	String icon = job_kind == TRASH || job_kind == DELETE ? ui::I_TRASH : job_kind == MOVE ? ui::I_CUT : job_kind == RESTORE ? ui::I_UNDO : job_kind == EXTRACT ? ui::I_FILE_ARCHIVE : ui::I_COPY;
	bool items = has_items();
	Rect head = { r.x, r.y, r.width - 88, PANEL_H };
	if (items && ui::hover(head)) { ui::outline(r, ui::BG3, 6); ui::tooltip(show_items ? "Hide the items" : "Show each item"); }
	ui::text(icon, x, r.y + 12, 18, ui::AQUA);
	ui::text_fit(txt::view(&title), x + 28, r.y + 13, w - (items ? 112 : 76), 16, ui::FG);
	bool can = cur.can_cancel;
	if (ui::icon_button({ r.x + r.width - 44, r.y + 8, 32, 30 }, ui::I_TIMES, can ? ui::FG4 : ui::BG3, can ? "Cancel (changes are rolled back)" : "Finishing…") && can) job.cancel();
	if (items && (ui::icon_button({ r.x + r.width - 80, r.y + 8, 32, 30 }, show_items ? ui::I_UP : ui::I_DOWN, ui::FG4, show_items ? "Hide the items" : "Show each item") || ui::clicked(head)))
	{
		show_items = !show_items;
		items_follow = true;
	}
	float frac = shown_frac;
	Rect bar = { x, r.y + 42, w, 8 };
	ui::panel(bar, ui::BG1, 4);
	if (cur.state == SCANNING || cur.state == CONFLICT)
	{
		// Indeterminate: a sliding segment while counting.
		float t = (float)(ui::now - job_started);
		float seg = w * 0.25f;
		float pos = (w - seg) * (0.5f + 0.5f * math::sin(t * 2.5f));
		ui::panel({ x + pos, bar.y, seg, bar.height }, ui::BG3, 4);
	}
	else if (frac > 0)
	{
		ui::panel({ x, bar.y, math::max(8.0f, w * math::min(frac, 1.0f)), bar.height }, ui::AQUA, 4);
	}
	ui::text_fit(txt::view(&detail), x, r.y + 59, w * 0.6f, 14, ui::FG4);
	String current = txt::view(&cur.current);
	if (current != "Undoing") ui::text_tail(current, x + w * 0.6f + 8, r.y + 59, w * 0.4f - 8, 14, ui::GRAY);
	float ih = items_height();
	if (ih > 0) draw_items({ x, r.y + PANEL_H, w, ih - 8 });
}

<* The expanded panel: one row per item (icon, name, own bar, size), virtualized, following the active item. *>
fn void draw_items(Rect list) => @pool()
{
	int n = job.item_count();
	ui::hline(list.x, list.y - 4, list.width, ui::BG2);
	float content = (float)n * ITEM_ROW;
	float wheel = ui::scroll_wheel(list, items_scroll, content);
	if (wheel != items_scroll) { items_scroll = wheel; items_follow = false; }
	if (items_follow && cur.item >= 0)
	{
		float top = (float)cur.item * ITEM_ROW;
		if (top < items_scroll) items_scroll = top;
		if (top + ITEM_ROW > items_scroll + list.height) items_scroll = top + ITEM_ROW - list.height;
		items_scroll = math::max(0.0f, math::min(items_scroll, content - list.height));
	}
	int first = (int)(items_scroll / ITEM_ROW);
	int want = math::min((int)(list.height / ITEM_ROW) + 2, (int)item_rows.len);
	int got = job.item_status(first, item_rows[:want]);
	ui::begin_clip(list);
	float nw = list.width * 0.52f;
	float bx = list.x + 24 + nw + 12;
	float bw = math::max(40.0f, list.width * 0.18f);
	float sx = bx + bw + 12;
	for (int k = 0; k < got; k++)
	{
		fileop::ItemProgress* it = &item_rows[k];
		float y = list.y + (float)(first + k) * ITEM_ROW - items_scroll;
		String icon = ui::I_CLOCK;
		Color ic = ui::BG3;
		switch (it.state)
		{
			case DONE: icon = ui::I_CHECK; ic = ui::GREEN;
			case ACTIVE: icon = ui::I_RIGHT; ic = ui::AQUA;
			case SKIPPED: icon = ui::I_FORWARD; ic = ui::YELLOW;
			default: break;
		}
		ui::text(icon, list.x + 2, y + 5, 14, ic);
		ui::text_fit(txt::view(&it.name), list.x + 24, y + 5, nw, 14, it.state == WAITING ? ui::FG4 : ui::FG);
		float f = it.bytes_total ? (float)it.bytes_done / (float)it.bytes_total : it.files_total ? (float)it.files_done / (float)it.files_total : it.state == DONE ? 1 : 0;
		if (it.state == DONE) f = 1;
		if (it.state == ACTIVE || it.state == DONE)
		{
			ui::panel({ bx, y + 10, bw, 6 }, ui::BG1, 3);
			if (f > 0) ui::panel({ bx, y + 10, math::max(6.0f, bw * math::min(f, 1.0f)), 6 }, it.state == ACTIVE ? ui::AQUA : ui::BG3, 3);
		}
		char[32] a, b;
		String size;
		if (it.state == SKIPPED) { size = "skipped"; }
		else if (it.bytes_total && it.state == ACTIVE)
		{
			size_text(&a, it.bytes_done);
			size_text(&b, it.bytes_total);
			size = string::tformat("%s of %s", txt::view(&a), txt::view(&b));
		}
		else if (it.bytes_total) { size_text(&a, it.bytes_total); size = txt::view(&a); }
		else if (it.files_total > 1) { size = string::tformat("%d items", it.files_total); }
		ui::text_fit(size, sx, y + 6, list.x + list.width - sx - 8, 12, ui::GRAY);
	}
	ui::end_clip();
	ui::scrollbar(list, items_scroll, content);
}

<* Modal dialogs (layer 1): name conflict, delete confirmation, quit while busy. *>
fn void draw_dialogs() => @pool()
{
	ui::layer = 1;
	if (ui::close_requested && job.busy())
	{
		Rect box = ui::dialog(520, 210);
		bool keep = ui::dialog_header(box, ui::I_WARN, "A file operation is running") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		bool undo = job_kind == COPY || job_kind == MOVE || job_kind == EXTRACT;
		ui::text_fit(txt::view(&title), box.x + 20, box.y + 62, box.width - 40, 15, ui::FG);
		ui::text_fit(undo ? "Quitting cancels it and rolls it back: nothing is lost." : "Quitting stops it; items already removed stay removed.", box.x + 20, box.y + 90, box.width - 40, 14, ui::FG4);
		if (ui::button({ box.x + 20, box.y + 140, 200, 40 }, "Keep running", PRIMARY)) keep = true;
		if (ui::button({ box.x + box.width - 220, box.y + 140, 200, 40 }, "Cancel and quit", DANGER))
		{
			job.close();
			ui::quit = true;
		}
		if (keep) ui::close_requested = false;
	}
	else if (job.busy() && cur.state == CONFLICT)
	{
		Rect box = ui::dialog(560, 230);
		bool cancel = ui::dialog_header(box, ui::I_WARN, cur.conflict_dir ? "Folder already exists" : "File already exists") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		ui::text_fit(string::tformat("\"%s\" already exists in \"%s\".", txt::view(&cur.conflict), txt::view(&job_target)), box.x + 20, box.y + 62, box.width - 40, 15, ui::FG);
		ui::text_fit("Replace deletes the existing one after the new one is complete.", box.x + 20, box.y + 88, box.width - 40, 13, ui::FG4);
		ui::checkbox(box.x + 20, box.y + 118, "Do this for all conflicts", &apply_all);
		float bw = (box.width - 40 - 24) / 4;
		float by = box.y + 168;
		if (ui::button({ box.x + 20, by, bw, 40 }, "Cancel")) cancel = true;
		if (ui::button({ box.x + 28 + bw, by, bw, 40 }, "Skip")) job.answer(SKIP, apply_all);
		if (ui::button({ box.x + 36 + bw * 2, by, bw, 40 }, "Keep both", PRIMARY)) job.answer(KEEP_BOTH, apply_all);
		if (ui::button({ box.x + 44 + bw * 3, by, bw, 40 }, "Replace", DANGER)) job.answer(REPLACE, apply_all);
		if (cancel) job.cancel();
	}
	else if (admin_open)
	{
		Rect box = ui::dialog(560, 264);
		bool cancel = ui::dialog_header(box, ui::I_LOCK, admin_for_open ? txt::view(&sudo_title) : "Permission denied") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		ui::text_fit(txt::view(&admin_error), box.x + 20, box.y + 60, box.width - 40, 14, ui::FG4);
		if (admin_delete) ui::text_fit("Root can't use your trash: this deletes permanently.", box.x + 20, box.y + 86, box.width - 40, 14, ui::FG);
		bool submitted;
		ui::secret_input(ID_ADMIN_PW, { box.x + 20, box.y + 118, box.width - 40, 40 }, &admin_pw, "Password for sudo", &submitted);
		if (ui::button({ box.x + 20, box.y + 196, 200, 40 }, "Cancel")) cancel = true;
		bool go = ui::button({ box.x + box.width - 260, box.y + 196, 240, 40 }, admin_delete ? "Delete as sudo" : admin_for_open ? "Open as sudo" : "Retry as sudo", admin_delete ? DANGER : PRIMARY) || submitted;
		if (go)
		{
			admin_open = false;
			ui::unfocus();
			if (admin_for_open) { open_as_sudo(); }
			else { retry_as_admin(); }
			admin_for_open = false;
		}
		else if (cancel)
		{
			admin_open = false;
			admin_for_open = false;
			ui::wipe(&admin_pw);
			ui::unfocus();
		}
	}
	else if (confirm_open)
	{
		update_count();
		Rect box = ui::dialog(520, 232);
		bool cancel = ui::dialog_header(box, ui::I_TRASH, pending_empty ? "Empty the trash?" : "Delete permanently?") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		String what = pending.count == 1 ? string::tformat("\"%s\"", pending.at(0)) : string::tformat("%d items", pending.count);
		String line = pending_fallback
			? string::tformat("%d of %s %s on another drive and can't go to the trash.", pending_untrashable, what, pending_untrashable == 1 ? "is" : "are")
			: pending_empty ? string::tformat("All %s in the trash will be deleted permanently.", pending.count == 1 ? "1 item" : string::tformat("%d items", pending.count))
			: string::tformat("%s will be deleted permanently.", what);
		ui::text_fit(line, box.x + 20, box.y + 62, box.width - 40, 15, ui::FG);
		if (!txt::empty(&count_text)) ui::text_fit(txt::view(&count_text), box.x + 20, box.y + 88, box.width - 40, 15, ui::YELLOW);
		ui::text_fit(pending_fallback ? "Delete those permanently and move the rest to the trash?" : "This cannot be undone.", box.x + 20, box.y + (pending_fallback ? 90 : 114), box.width - 40, 14, ui::FG4);
		if (ui::button({ box.x + 20, box.y + 162, 200, 40 }, "Cancel")) cancel = true;
		if (ui::button({ box.x + box.width - 220, box.y + 162, 200, 40 }, pending_empty ? "Empty trash" : "Delete", DANGER))
		{
			confirm_open = false;
			counter.close();
			counting = false;
			begin(pending_fallback ? TRASH : DELETE, txt::view(&pending.dir), pending.tview(), "", pending_fallback);
		}
		if (cancel)
		{
			confirm_open = false;
			counter.close();
			counting = false;
		}
	}
	else if (new_open)
	{
		Rect box = ui::dialog(520, 240);
		bool cancel = ui::dialog_header(box, new_folder ? ui::I_FOLDER : ui::I_FILE, new_folder ? "New folder" : "New file") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		String dir = txt::view(&new_dir);
		ui::text_fit(string::tformat("in %s", dir == "/" ? "/" : txt::basename(dir)), box.x + 20, box.y + 60, box.width - 40, 14, ui::FG4);
		bool submitted;
		if (ui::input(ID_NEW_NAME, { box.x + 20, box.y + 88, box.width - 40, 40 }, &new_name, new_folder ? "Folder name" : "File name", &submitted)) new_error[0] = 0;
		if (!txt::empty(&new_error)) ui::text_fit(txt::view(&new_error), box.x + 20, box.y + 140, box.width - 40, 14, ui::RED);
		if (ui::button({ box.x + 20, box.y + 176, 200, 40 }, "Cancel")) cancel = true;
		if ((ui::button({ box.x + box.width - 220, box.y + 176, 200, 40 }, "Create", PRIMARY) || submitted) && create_new()) { new_open = false; ui::unfocus(); }
		else if (cancel) { new_open = false; ui::unfocus(); }
	}
	ui::layer = 0;
}
