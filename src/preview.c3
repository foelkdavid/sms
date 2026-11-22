module sms::preview;
import std::math, std::core::string;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::image;

image::Loader loader;
bool active;
bool loading;
rl::RLTexture2D texture;
char[256] name;
char[80] dimensions;
String error;

fn bool supported(String filename)
{
	return txt::iends_with(filename, ".png") || txt::iends_with(filename, ".jpg") ||
		txt::iends_with(filename, ".jpeg") || txt::iends_with(filename, ".bmp") || txt::iends_with(filename, ".gif");
}

fn void clear()
{
	loader.cancel();
	if (texture.id) rl::unload_texture(texture);
	texture = {};
	active = false;
	loading = false;
	error = "";
}

// Only called on selection/navigation, never as part of drawing a row.
fn void select(String path)
{
	clear();
	if (!supported(path)) return;
	active = true;
	loading = true;
	txt::set(&name, txt::basename(path));
	if (!loader.request(path)) { loading = false; error = "Could not start image loader"; }
}

fn void poll() => @pool()
{
	image::Result result;
	if (!loader.take(&result)) return;
	loading = false;
	if (result.status != READY)
	{
		switch (result.status)
		{
			case TOO_LARGE: error = "Image exceeds preview limits";
			case READ_ERROR: error = "Cannot read this image";
			case NO_MEMORY: error = "Not enough memory";
			default: error = "Invalid or unsupported image";
		}
		return;
	}
	defer rl::unload_image(result.pixels);
	texture = rl::load_texture_from_image(result.pixels);
	if (!texture.id) { error = "Could not upload image"; return; }
	texture.set_filter(rl::RLTextureFilter.BILINEAR);
	txt::set(&dimensions, string::tformat("%d × %d px", result.width, result.height));
}

fn void draw(Rect panel)
{
	ui::panel(panel, ui::BG_HARD, 4);
	ui::begin_clip(panel);
	defer ui::end_clip();
	ui::text_fit(txt::view(&name), panel.x + 12, panel.y + 14, panel.width - 24, 18, ui::FG);
	Rect area = { panel.x + 12, panel.y + 48, panel.width - 24, panel.height - 88 };
	if (loading) { ui::text_fit("Loading…", area.x, area.y + 12, area.width, 16, ui::GRAY); return; }
	if (error.len)
	{
		ui::text_fit(error, area.x, area.y + 12, area.width, 16, ui::GRAY);
		if (error == "Image exceeds preview limits")
		{
			ui::text_fit("32 MiB file · 32 MP", area.x, area.y + 40, area.width, 14, ui::GRAY);
			ui::text_fit("Max edge: 16384 px", area.x, area.y + 62, area.width, 14, ui::GRAY);
		}
		return;
	}
	if (!texture.id || area.width <= 0 || area.height <= 0) return;
	float factor = math::min(1 / ui::scale, math::min(area.width / (float)texture.width, area.height / (float)texture.height));
	float w = (float)texture.width * factor;
	float h = (float)texture.height * factor;
	Rect target = { area.x + (area.width - w) / 2, area.y + (area.height - h) / 2, w, h };
	rl::draw_texture_pro(texture, { 0, 0, (float)texture.width, (float)texture.height }, target, { 0, 0 }, 0, rl::WHITE);
	ui::text_fit(txt::view(&dimensions), panel.x + 12, panel.y + panel.height - 27, panel.width - 24, 15, ui::GRAY);
}

fn void close()
{
	clear();
	loader.close();
}
