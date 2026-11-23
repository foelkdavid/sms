module sms::arc;
import std::core::string, libc;
import bmu::ui, bmu::txt, bmu::sys, bmu::archive;

// Browsing archives (read-only) and temporary copies for opening files from them.
//
// The shown "folder" is `file` + "/" + `inner`; the listing comes from one bmu::archive::Index read in the
// background when the archive is entered (memory only afterwards: no disk I/O per folder). Opening a file from
// an archive extracts it into a private temporary folder (`$XDG_RUNTIME_DIR/sms-open-UID-PID`, fallback /tmp)
// that is removed on exit, also after SIGTERM / SIGINT / SIGHUP; folders left by a crashed sms are swept the
// next time a temporary copy is made.

extern fn CInt c_getpid() @cname("getpid");
extern fn CUInt c_getuid() @cname("getuid");
extern fn CInt c_kill(CInt pid, CInt sig) @cname("kill");
extern fn CInt* c_errno() @cname("__errno_location");
extern fn CInt c_nftw(ZString path, NftwFn f, CInt fds, CInt flags) @cname("nftw");
extern fn CInt c_remove(ZString path) @cname("remove");
alias NftwFn = fn CInt(ZString path, libc::Stat* st, CInt flag, void* ftw);
const CInt FTW_PHYS = 1;
const CInt FTW_DEPTH = 8;
const CInt ESRCH = 3;

bool active;
char[4096] file;   // archive being browsed (resolved path)
char[4096] inner;  // normalized folder inside it ("" = root)
archive::Index index;
bool listed;       // the listing reflects the ready index
int shown_seen = -1;
char[96] loading_text;

char[4096] temp_root; // empty until the first temporary copy
int temp_seq;
bool signalled;       // quit normally (temporary copies are removed on the way out)

<*
 Split `path` (absolute) into an archive file and a folder inside it: the longest existing prefix that is a
 regular file with an archive extension. A few stats, on navigation only.
*>
fn bool locate(String path, char[] arc_out, char[] inner_out) => @pool()
{
	if (!path.starts_with("/")) return false;
	for (usz i = path.len; i > 1; i--)
	{
		if (i < path.len && path[i] != '/') continue;
		String prefix = path[:i];
		libc::Stat st;
		if (libc::stat(prefix.zstr_tcopy(), &st) != 0) continue;
		if ((st.st_mode & 0xF000) == 0x4000) return false; // a real folder: deeper parts just don't exist
		if ((st.st_mode & 0xF000) != 0x8000 || !archive::is_archive(txt::basename(prefix))) return false;
		if (archive::normalize(path[i..], inner_out) < 0) return false;
		sys::realpath(arc_out, prefix);
		return true;
	}
	return false;
}

<* Show folder `rel` of archive `path` (re-reading only for another archive). False when it can't be shown. *>
fn bool enter(String path, String rel)
{
	if (!archive::load()) { ui::toast("Archives need libarchive (not installed)", ui::RED); return false; }
	if (!active || index.file() != path)
	{
		index.close();
		if (!index.start(path)) { ui::toast("Could not read the archive", ui::RED); return false; }
		listed = false;
		shown_seen = -1;
	}
	if (index.phase() == READY && !index.has_dir(rel)) return false;
	active = true;
	txt::set(&file, path);
	txt::set(&inner, rel);
	return true;
}

<* F5 inside an archive: read it again. *>
fn void reread()
{
	if (!active) return;
	index.close();
	listed = false;
	shown_seen = -1;
	if (!index.start(txt::view(&file))) ui::toast("Could not read the archive", ui::RED);
}

fn void leave()
{
	if (!active) return;
	index.close();
	active = false;
	listed = false;
}

fn bool ready() => active && index.phase() == READY;

<* The path shown for the current archive folder. *>
fn void display(char[] out)
{
	txt::set(out, txt::view(&file));
	if (!txt::empty(&inner)) { txt::append(out, "/"); txt::append(out, txt::view(&inner)); }
}

<* Listing of the current folder (0 while loading). *>
fn int list(sys::Entry[] out)
{
	if (!ready()) return 0;
	return index.list(txt::view(&inner), out, true);
}

<* Normalized path of `name` in the current folder (temp). *>
fn String rel(String name) => txt::empty(&inner) ? name : string::tformat("%s/%s", txt::view(&inner), name);

<* Index entry of `name` in the current folder, or -1. *>
fn int find(String name) => @pool() { return ready() ? index.find(rel(name)) : -1; }

<*
 Once per frame (one lock while loading): 1 = the index just became ready (list it now), 2 = it failed.
 Keeps `loading_text` current without formatting every frame.
*>
fn int poll() => @pool()
{
	if (!active || listed) return 0;
	switch (index.phase())
	{
		case READY:
			listed = true;
			if (!index.has_dir(txt::view(&inner))) inner[0] = 0;
			return 1;
		case FAILED:
		case IDLE:
			listed = true;
			return 2;
		default:
			int seen;
			ulong done, total;
			index.progress(&seen, &done, &total);
			if (seen != shown_seen)
			{
				shown_seen = seen;
				int pct = total ? (int)(done * 100 / total) : 0;
				txt::set(&loading_text, string::tformat("Reading archive… %d entries (%d%%)", seen, pct));
			}
			return 0;
	}
}

fn void on_signal(CInt sig) => signalled = true;

fn CInt remove_one(ZString path, libc::Stat* st, CInt flag, void* ftw) { c_remove(path); return 0; }

<* rm -rf without following links; only for our own temporary folders. *>
fn void remove_tree(String path) => @pool()
{
	libc::Stat st;
	if (libc::lstat(path.zstr_tcopy(), &st) != 0 || (st.st_mode & 0xF000) != 0x4000 || st.st_uid != c_getuid()) return;
	c_nftw(path.zstr_tcopy(), &remove_one, 16, FTW_PHYS | FTW_DEPTH);
}

fn String temp_base()
{
	String run = sys::env("XDG_RUNTIME_DIR");
	return run.starts_with("/") && sys::is_dir(run) ? run : "/tmp";
}

<* Remove temporary folders of sms processes that no longer run (crash, SIGKILL). *>
fn void sweep(String base) => @pool()
{
	String mine = string::tformat("sms-open-%d-", c_getuid());
	void* d = sys::c_opendir(base.zstr_tcopy());
	if (!d) return;
	defer sys::c_closedir(d);
	while (true)
	{
		sys::Dirent* e = sys::c_readdir(d);
		if (!e) break;
		String name = ((ZString)&e.name).str_view();
		if (!name.starts_with(mine)) continue;
		int? pid = name[mine.len..].to_int();
		if (catch pid) continue;
		if (pid <= 0 || pid == c_getpid()) continue;
		if (c_kill(pid, 0) == 0 || *c_errno() != ESRCH) continue;
		remove_tree(txt::join(base, name));
	}
}

<* A new private folder for one temporary copy (temp result), or "" on failure. *>
fn String new_temp_dir()
{
	if (txt::empty(&temp_root))
	{
		String base = temp_base();
		sweep(base);
		String root = txt::join(base, string::tformat("sms-open-%d-%d", c_getuid(), c_getpid()));
		if (sys::c_mkdir(root.zstr_tcopy(), 0o700) != 0 && !sys::is_dir(root)) return "";
		libc::Stat st;
		if (libc::lstat(root.zstr_tcopy(), &st) != 0 || (st.st_mode & 0xF000) != 0x4000 || st.st_uid != c_getuid()) return "";
		txt::set(&temp_root, root);
		libc::signal(libc::SIGTERM, &on_signal);
		libc::signal(libc::SIGINT, &on_signal);
		libc::signal(libc::SIGHUP, &on_signal);
	}
	String dir = txt::join(txt::view(&temp_root), string::tformat("%d", ++temp_seq));
	if (sys::c_mkdir(dir.zstr_tcopy(), 0o700) != 0) return "";
	return dir;
}

<* On exit (after file operations stopped): remove the temporary copies and free the index. *>
fn void cleanup()
{
	index.close();
	if (!txt::empty(&temp_root)) remove_tree(txt::view(&temp_root));
	temp_root[0] = 0;
}
