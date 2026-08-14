const std = @import("std");
const c = @cImport({
    @cInclude("freetype2/ft2build.h");
    @cInclude("freetype2/freetype.h");
});

const Config = @import("config.zig").Config;
const log = std.log.scoped(.font);

pub const FontAtlas = struct {
    allocator: std.mem.Allocator,
    ft_library: ?c.FT_Library,
    ft_face: ?c.FT_Face,
    atlas_data: []u8,
    atlas_width: u32,
    atlas_height: u32,
    glyphs: [128]Glyph,
    font_size: i32,
    ascent: i32,
    line_height: i32,

    pub const Glyph = struct {
        atlas_x: u32,
        atlas_y: u32,
        width: i32,
        height: i32,
        left: i32,
        top: i32,
        advance: i32,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: *const Config) !FontAtlas {
        var ft_library: c.FT_Library = null;
        var ft_face: c.FT_Face = null;

        var err = c.FT_Init_FreeType(&ft_library);
        if (err != 0) {
            log.err("failed to init freetype: {}", .{err});
            return error.FreetypeInitFailed;
        }

        err = c.FT_New_Face(ft_library, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 0, &ft_face);
        if (err != 0) {
            _ = c.FT_Done_FreeType(ft_library);
            log.err("failed to load font: {}", .{err});
            return error.FontLoadFailed;
        }

        err = c.FT_Set_Pixel_Sizes(ft_face, 0, cfg.bar.font_size);
        if (err != 0) {
            _ = c.FT_Done_Face(ft_face);
            _ = c.FT_Done_FreeType(ft_library);
            log.err("failed to set font size: {}", .{err});
            return error.FontSizeFailed;
        }

        const atlas_size = 512;
        const atlas_data = try allocator.alloc(u8, atlas_size * atlas_size);
        @memset(atlas_data, 0);

        var font_atlas = FontAtlas{
            .allocator = allocator,
            .ft_library = ft_library,
            .ft_face = ft_face,
            .atlas_data = atlas_data,
            .atlas_width = atlas_size,
            .atlas_height = atlas_size,
            .glyphs = undefined,
            .font_size = cfg.bar.font_size,
            .ascent = 0,
            .line_height = 0,
        };

        font_atlas.buildAtlas();
        return font_atlas;
    }

    fn buildAtlas(self: *FontAtlas) void {
        var pen_x: u32 = 0;
        var pen_y: u32 = 0;
        var max_height: u32 = 0;

        if (self.ft_face) |face| {
            self.ascent = face.*.size.*.metrics.ascender >> 6;
            self.line_height = face.*.size.*.metrics.height >> 6;
        }

        var char: u8 = 32;
        while (char < 127) : (char += 1) {
            const err = c.FT_Load_Char(self.ft_face, char, c.FT_LOAD_RENDER);
            if (err != 0) {
                self.glyphs[char] = .{
                    .atlas_x = 0,
                    .atlas_y = 0,
                    .width = 0,
                    .height = 0,
                    .left = 0,
                    .top = 0,
                    .advance = 0,
                };
                continue;
            }

            if (self.ft_face) |face| {
                const glyph = face.*.glyph.*;
                const w = glyph.bitmap.width;
                const h = glyph.bitmap.rows;

                if (pen_x + w >= self.atlas_width) {
                    pen_x = 0;
                    pen_y += max_height + 1;
                    max_height = 0;
                }

                var bitmap_row: c.FT_Int = 0;
                while (bitmap_row < h) : (bitmap_row += 1) {
                    var bitmap_col: c.FT_Int = 0;
                    while (bitmap_col < w) : (bitmap_col += 1) {
                        const src_idx = @as(usize, @intCast(bitmap_row * glyph.bitmap.pitch + bitmap_col));
                        const dst_x = pen_x + @as(u32, @intCast(bitmap_col));
                        const dst_y = pen_y + @as(u32, @intCast(bitmap_row));
                        const dst_idx = dst_y * self.atlas_width + dst_x;

                        if (dst_idx < self.atlas_data.len and src_idx < @as(usize, @intCast(h * @as(u32, @intCast(glyph.bitmap.pitch))))) {
                            self.atlas_data[dst_idx] = glyph.bitmap.buffer[src_idx];
                        }
                    }
                }

                self.glyphs[char] = .{
                    .atlas_x = pen_x,
                    .atlas_y = pen_y,
                    .width = @intCast(w),
                    .height = @intCast(h),
                    .left = @intCast(glyph.bitmap_left),
                    .top = @intCast(glyph.bitmap_top),
                    .advance = @intCast(glyph.advance.x >> 6),
                };

                pen_x += w + 1;
                if (h > max_height) {
                    max_height = h;
                }
            }
        }
    }

    pub fn getGlyph(self: *FontAtlas, char: u8) ?Glyph {
        if (char >= 128) return null;
        const g = self.glyphs[char];
        if (g.width == 0 and g.height == 0) return null;
        return g;
    }

    pub fn getAtlasPixel(self: *FontAtlas, x: u32, y: u32) u8 {
        if (x >= self.atlas_width or y >= self.atlas_height) return 0;
        const idx = y * self.atlas_width + x;
        if (idx >= self.atlas_data.len) return 0;
        return self.atlas_data[idx];
    }

    pub fn textWidth(self: *FontAtlas, text: []const u8) i32 {
        var width: i32 = 0;
        for (text) |char| {
            if (self.getGlyph(char)) |glyph| {
                width += glyph.advance;
            }
        }
        return width;
    }

    pub fn deinit(self: *FontAtlas) void {
        self.allocator.free(self.atlas_data);
        if (self.ft_face) |face| {
            _ = c.FT_Done_Face(face);
        }
        if (self.ft_library) |lib| {
            _ = c.FT_Done_FreeType(lib);
        }
    }
};
