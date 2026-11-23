module sms::ops;
import std::math, std::core::string, libc;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::fileop;
import sms::prefs, sms::openers;

// File operations: clipboard (Ctrl+C / Ctrl+X / Ctrl+V), drag moves, Del / Shift+Del, one background
// bmu::fileop job with a docked progress bar, conflict / delete / quit dialogs. All disk work runs on the
// job's worker; this module only polls it once per frame (one lock, no I/O).

const float PANEL_H = 84;

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
Names pending;                 // waiting for the delete confirmation
// The running request, kept for "Retry as administrator" after a permission error.
Names req;
fileop::Kind req_kind;
char[4096] req_dst;
bool req_fallback;
bool req_elevated;
bool admin_open;
bool admin_for_open;           // the dialog asks for "Open as sudo" (not a retry of a file operation)
char[4096] sudo_path;          // file to open as sudo
fileop::SudoRun[4] sudo_runs;  // programs started as root (each drained/reaped by its own thread)
bool admin_delete;             // TRASH failed: the retry deletes permanently as root (root's trash is not yours)
char[256] admin_pw;            // wiped on submit / cancel / close
char[512] admin_error;
const int ID_ADMIN_PW = 50;
bool confirm_open;
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
double sample_time;
ulong sample_bytes;
double speed;                  // bytes / s, smoothed

fn bool busy() => job.busy();
fn bool modal() => confirm_open || admin_open || ui::close_requested || (job.busy() && cur.state == CONFLICT);
fn bool has_clip() => clip.count > 0;
<* Entry names cut to the clipboard are drawn dimmed while their folder is shown. *>
fn bool is_cut(String dir) => clip_cut && clip.count > 0 && txt::view(&clip.dir) == dir;

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
	bool ok = elevated ? job.start_elevated(kind, src_dir, names, dst_dir, password, fallback) : job.start(kind, src_dir, names, dst_dir, fallback);
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
	sample_bytes = 0;
	speed = 0;
	apply_all = false;
	String what = names.len == 1 ? string::tformat("\"%s\"", names[0]) : string::tformat("%d items", names.len);
	switch (kind)
	{
		case COPY: txt::set(&title, string::tformat("Copying %s to %s", what, txt::view(&job_target)));
		case MOVE: txt::set(&title, string::tformat("Moving %s to %s", what, txt::view(&job_target)));
		case TRASH: txt::set(&title, string::tformat("Moving %s to the trash", what));
		case DELETE: txt::set(&title, string::tformat("Deleting %s", what));
		case COUNT: txt::set(&title, string::tformat("Counting %s", what));
		case RESTORE: txt::set(&title, string::tformat("Restoring %s", what));
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

fn void set_clipboard(String dir, String[] names, bool cut) => @pool()
{
	if (!names.len) return;
	if (!clip.set(dir, names)) { ui::toast("Too many items for the clipboard", ui::RED); return; }
	clip_cut = cut;
	ui::toast(string::tformat("%s %d %s", cut ? "Cut" : "Copied", names.len, plural((int)names.len, "item", "items")));
}

fn void paste(String dst) => @pool()
{
	if (!clip.count) return;
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
	confirm_open = true;
	// Count in the background: the dialog opens at once and fills in "N items, X GB" as the scan runs.
	counter.close();
	counting = !pending_fallback && counter.start(COUNT, dir, names);
	counted = {};
	count_shown = -1;
	txt::set(&count_text, counting ? "Counting…" : "");
}

<* Once per frame, before input: progress snapshot, finish handling, close guard. *>
fn void poll() => @pool()
{
	poll_sudo();
	fileop::Progress done;
	if (job.finished(&done))
	{
		cur = done;
		refresh = true;
		size_dirty = true;
		finished(&done);
	}
	else if (job.busy())
	{
		job.status(&cur);
		if (ui::now - sample_time >= 0.25) update_detail();
	}
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
				case COUNT: break;
			}
		case CANCELLED:
			ui::toast(job_kind == COPY || job_kind == MOVE ? "Cancelled: nothing was changed" : "Cancelled", ui::YELLOW);
		default:
			// Permission denied: offer the same operation as administrator (not for restore / sizing).
			bool denied = p.err == 13 || p.err == 1;
			bool wrong_pw = req_elevated && txt::view(&p.error) == "Wrong password";
			if ((denied && !req_elevated && job_kind != RESTORE && job_kind != COUNT) || wrong_pw)
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

<* Right-click → Open as sudo: ask for the password, then run the file's opener command as root. *>
fn void ask_open_as_sudo(String path) => @pool()
{
	char[1024] storage;
	ZString[openers::MAX_COMMAND_ARGS] cmd;
	int n = openers::command_for(txt::basename(path), &storage, &cmd);
	if (n == -1) { ui::toast("No matching file opener. Configure one with Ctrl+K.", ui::RED); return; }
	if (n < 0) { ui::toast("This opener's command is empty or has an unclosed quote", ui::RED); return; }
	txt::set(&sudo_path, path);
	String shown;
	for (int i = 0; i < n; i++) shown = i ? string::tformat("%s %s", shown, cmd[i].str_view()) : cmd[i].str_view().tcopy();
	txt::set(&admin_error, string::tformat("%s with %s", txt::basename(path), shown));
	admin_for_open = true;
	admin_delete = false;
	ui::wipe(&admin_pw);
	admin_open = true;
	ui::focus = ID_ADMIN_PW;
}

fn void open_as_sudo() => @pool()
{
	String path = txt::view(&sudo_path);
	char[1024] storage;
	ZString[openers::MAX_COMMAND_ARGS] cmd;
	int n = openers::command_for(txt::basename(path), &storage, &cmd);
	if (n < 0) { ui::wipe(&admin_pw); return; }
	String[] argv = mem::talloc_array(String, (usz)n + 1);
	for (int i = 0; i < n; i++) argv[i] = cmd[i].str_view();
	argv[n] = path;
	fileop::SudoRun* free_run;
	foreach (&r : sudo_runs) if (!r.started) { free_run = r; break; }
	if (!free_run) { ui::toast("Too many programs running as sudo", ui::RED); }
	else if (!free_run.start(argv, &admin_pw)) { ui::toast("Could not start sudo", ui::RED); }
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

fn void update_detail() => @pool()
{
	double dt = ui::now - sample_time;
	if (cur.bytes_done >= sample_bytes && dt > 0)
	{
		double now_speed = (double)(cur.bytes_done - sample_bytes) / dt;
		speed = speed <= 0 ? now_speed : speed * 0.7 + now_speed * 0.3;
	}
	sample_time = ui::now;
	sample_bytes = cur.bytes_done;
	char[32] a, b, c, d;
	switch (cur.state)
	{
		case SCANNING:
		case CONFLICT:
			size_text(&a, cur.bytes_total);
			txt::set(&detail, string::tformat("Preparing… %d files, %s", cur.files_total, txt::view(&a)));
		case FINISHING:
			txt::set(&detail, cur.can_cancel ? "Finishing…" : txt::view(&cur.current) == "Undoing" ? "Undoing changes…" : "Finishing…");
		default:
			if (cur.bytes_total > 0)
			{
				size_text(&a, cur.bytes_done);
				size_text(&b, cur.bytes_total);
				size_text(&c, (ulong)speed);
				if (speed > 1) { time_text(&d, (double)(cur.bytes_total - cur.bytes_done) / speed); }
				else { txt::set(&d, "—"); }
				txt::set(&detail, string::tformat("%s of %s · %s/s · %s left", txt::view(&a), txt::view(&b), txt::view(&c), txt::view(&d)));
			}
			else
			{
				txt::set(&detail, string::tformat("%d of %d", cur.files_done, math::max(cur.files_total, cur.files_done)));
			}
	}
}

<* Height of the docked progress bar this frame (0 = hidden). Instant jobs never flash it. *>
fn float panel_height() => job.busy() && (ui::now - job_started > 0.25 || cur.state == CONFLICT) ? PANEL_H : 0;

<* Docked progress bar (layer 0) below the file list. *>
fn void draw_panel(Rect r)
{
	if (r.height <= 0) return;
	ui::panel(r, ui::BG_HARD, 6);
	ui::outline(r, ui::BG2, 6);
	float x = r.x + 14;
	float w = r.width - 28;
	String icon = job_kind == TRASH || job_kind == DELETE ? ui::I_TRASH : job_kind == MOVE ? ui::I_CUT : job_kind == RESTORE ? ui::I_UNDO : ui::I_COPY;
	ui::text(icon, x, r.y + 12, 18, ui::AQUA);
	ui::text_fit(txt::view(&title), x + 28, r.y + 13, w - 76, 16, ui::FG);
	bool can = cur.can_cancel;
	if (ui::icon_button({ r.x + r.width - 44, r.y + 8, 32, 30 }, ui::I_TIMES, can ? ui::FG4 : ui::BG3, can ? "Cancel (changes are rolled back)" : "Finishing…") && can) job.cancel();
	float frac;
	if (cur.bytes_total > 0) { frac = (float)cur.bytes_done / (float)cur.bytes_total; }
	else if (cur.files_total > 0) { frac = (float)cur.files_done / (float)cur.files_total; }
	if (cur.state == FINISHING) frac = 1;
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
}

<* Modal dialogs (layer 1): name conflict, delete confirmation, quit while busy. *>
fn void draw_dialogs() => @pool()
{
	ui::layer = 1;
	if (ui::close_requested && job.busy())
	{
		Rect box = ui::dialog(520, 210);
		bool keep = ui::dialog_header(box, ui::I_WARN, "A file operation is running") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		bool undo = job_kind == COPY || job_kind == MOVE;
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
		bool cancel = ui::dialog_header(box, ui::I_LOCK, admin_for_open ? "Open as sudo" : "Permission denied") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
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
		bool cancel = ui::dialog_header(box, ui::I_TRASH, "Delete permanently?") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
		String what = pending.count == 1 ? string::tformat("\"%s\"", pending.at(0)) : string::tformat("%d items", pending.count);
		String line = pending_fallback
			? string::tformat("%d of %s %s on another drive and can't go to the trash.", pending_untrashable, what, pending_untrashable == 1 ? "is" : "are")
			: string::tformat("%s will be deleted permanently.", what);
		ui::text_fit(line, box.x + 20, box.y + 62, box.width - 40, 15, ui::FG);
		if (!txt::empty(&count_text)) ui::text_fit(txt::view(&count_text), box.x + 20, box.y + 88, box.width - 40, 15, ui::YELLOW);
		ui::text_fit(pending_fallback ? "Delete those permanently and move the rest to the trash?" : "This cannot be undone.", box.x + 20, box.y + (pending_fallback ? 90 : 114), box.width - 40, 14, ui::FG4);
		if (ui::button({ box.x + 20, box.y + 162, 200, 40 }, "Cancel")) cancel = true;
		if (ui::button({ box.x + box.width - 220, box.y + 162, 200, 40 }, "Delete", DANGER))
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
	ui::layer = 0;
}
