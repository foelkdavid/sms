module openers_check;
import std::io;
import bmu::sys, bmu::txt;
import sms::prefs, sms::openers;

// Pass a fresh temporary directory, never a real sms configuration directory.
fn void main(String[] args) => @pool()
{
	assert(args.len == 2);
	txt::set(&prefs::config_dir, args[1]);
	openers::load();
	assert(openers::count == 1);
	assert(txt::view(&openers::rules[0].pattern) == "*.pdf");
	assert(txt::view(&openers::rules[0].executable) == "firefox-esr");
	assert(txt::empty(&openers::error));
	assert(openers::matches("*.png,*.jpg,*.jpeg", "photo.png"));
	assert(openers::matches("*.png,*.jpg,*.jpeg", "photo.jpg"));
	assert(openers::matches("*.png,*.jpg,*.jpeg", "photo.jpeg"));
	assert(openers::matches(" *.png , *.jpg , *.jpeg ", "photo.jpeg"));
	assert(!openers::matches("*.png,*.jpg,*.jpeg", "photo.pdf"));
	assert(!openers::matches("*.png,*.jpg,*.jpeg", "photo.JPG"));
	assert(openers::valid("*.png, *.jpg", "/bin/true"));
	assert(!openers::valid("*.png,", "/bin/true"));
	assert(!openers::valid(",*.png", "/bin/true"));
	assert(!openers::valid("*.png, ,*.jpg", "/bin/true"));
	String path = openers::config_path();
	assert(sys::write_file(path, "# comment\n\n *.pdf | /bin/true \n* | /bin/false\n"));
	openers::load();
	assert(openers::count == 2);
	assert(txt::view(&openers::rules[0].executable) == "/bin/true");
	assert(!openers::fnmatch("*.pdf", "a space;$(touch BAD).pdf", 0));
	assert(openers::fnmatch("*.pdf", "a.PDF", 0) != 0);
	openers::launch("/tmp/a space;$(touch BAD).pdf");
	bool reaped;
	for (int i = 0; i < 100; i++)
	{
		openers::poll();
		if (!openers::children[0]) { reaped = true; break; }
		sys::c_usleep(10000);
	}
	assert(reaped);
	assert(openers::save());
	openers::load();
	assert(openers::count == 2);
	assert(sys::write_file(path, "*.png, *.jpg, *.jpeg | /bin/true\n"));
	openers::load();
	assert(openers::count == 1);
	assert(openers::save());
	openers::load();
	assert(txt::view(&openers::rules[0].pattern) == "*.png, *.jpg, *.jpeg");
	assert(openers::matches(txt::view(&openers::rules[0].pattern), "photo.jpg"));
	assert(sys::write_file(path, "*.png, | /bin/true\n"));
	openers::load();
	assert(openers::count == 0 && !txt::empty(&openers::error));
	assert(sys::write_file(path, ""));
	openers::load();
	assert(openers::count == 0 && txt::empty(&openers::error));
	assert(sys::write_file(path, "broken rule\n"));
	openers::load();
	assert(openers::count == 0 && !txt::empty(&openers::error));
	assert(sys::write_file(path, "*.pdf | executable | extra\n"));
	openers::load();
	assert(openers::count == 0 && !txt::empty(&openers::error));
	char[3000] many;
	for (int i = 0; i < 17; i++) txt::append(&many, "* | /bin/true\n");
	assert(sys::write_file(path, txt::view(&many)));
	openers::load();
	assert(openers::count == 0 && !txt::empty(&openers::error));
	char[22000] oversized;
	for (int i = 0; i < oversized.len; i++) oversized[i] = '#';
	assert(sys::write_file(path, (String)oversized[..]));
	openers::load();
	assert(openers::count == 0 && !txt::empty(&openers::error));
	openers::count = 1;
	txt::set(&openers::rules[0].pattern, "  *.pdf  ");
	txt::set(&openers::rules[0].executable, " /bin/true ");
	assert(openers::save());
	openers::load();
	assert(txt::view(&openers::rules[0].pattern) == "*.pdf");
	assert(txt::view(&openers::rules[0].executable) == "/bin/true");
	txt::set(&openers::rules[0].executable, "");
	assert(!openers::save());
	openers::load();
	assert(txt::view(&openers::rules[0].executable) == "/bin/true");
	io::printn("Headless opener checks passed.");
}
