const std = @import("std");

const FontAtlas = @import("font.zig").FontAtlas;
const ShmPool = @import("shm.zig").ShmPool;

const log = std.log.scoped(.renderer);

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    font: *FontAtlas,
    shm: *ShmPool,

    pub fn init(allocator: std.mem.Allocator, font: *FontAtlas, shm: *ShmPool) !Renderer {
        return .{
            .allocator = allocator,
            .font = font,
            .shm = shm,
        };
    }

    pub fn clear(self: *Renderer, color: u32) void {
        const canvas = self.shm.getCanvas();
        for (canvas) |*pixel| {
            pixel.* = color;
        }
    }

    pub fn fillRect(self: *Renderer, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        const canvas = self.shm.getCanvas();
        const sw = @as(i32, @intCast(self.shm.width));
        const sh = @as(i32, @intCast(self.shm.height));

        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, sw);
        const y1 = @min(y + h, sh);

        var row = y0;
        while (row < y1) : (row += 1) {
            var col = x0;
            while (col < x1) : (col += 1) {
                const idx = @as(usize, @intCast(row * sw + col));
                if (idx < canvas.len) {
                    canvas[idx] = color;
                }
            }
        }
    }

    pub fn drawText(self: *Renderer, x: i32, y: i32, text: []const u8, color: u32) i32 {
        var cursor = x;
        for (text) |char| {
            if (self.font.getGlyph(char)) |glyph| {
                self.blitGlyph(cursor, y, glyph, color);
                cursor += @intCast(glyph.advance);
            }
        }
        return cursor;
    }

    fn blitGlyph(self: *Renderer, x: i32, y: i32, glyph: FontAtlas.Glyph, color: u32) void {
        const canvas = self.shm.getCanvas();
        const sw = @as(i32, @intCast(self.shm.width));
        const sh = @as(i32, @intCast(self.shm.height));

        const a = @as(u8, @intCast((color >> 24) & 0xFF));
        const r = @as(u8, @intCast((color >> 16) & 0xFF));
        const g = @as(u8, @intCast((color >> 8) & 0xFF));
        const b = @as(u8, @intCast(color & 0xFF));

        var gy: i32 = 0;
        while (gy < glyph.height) : (gy += 1) {
            var gx: i32 = 0;
            while (gx < glyph.width) : (gx += 1) {
                const px = x + gx + glyph.left;
                const py = y + gy - glyph.top + @as(i32, @intCast(self.font.ascent));

                if (px < 0 or px >= sw or py < 0 or py >= sh) continue;

                const atlas_x = glyph.atlas_x + @as(u32, @intCast(gx));
                const atlas_y = glyph.atlas_y + @as(u32, @intCast(gy));
                const alpha = self.font.getAtlasPixel(atlas_x, atlas_y);

                if (alpha == 0) continue;

                const blend = @as(u32, alpha);
                const inv = 255 - blend;
                const dst = canvas[@as(usize, @intCast(py * sw + px))];
                const dr = @as(u32, @intCast((dst >> 16) & 0xFF));
                const dg = @as(u32, @intCast((dst >> 8) & 0xFF));
                const db = @as(u32, @intCast(dst & 0xFF));

                const nr = (r * blend + dr * inv) / 255;
                const ng = (g * blend + dg * inv) / 255;
                const nb = (b * blend + db * inv) / 255;

                canvas[@as(usize, @intCast(py * sw + px))] = 0xFF000000 | (nr << 16) | (ng << 8) | nb;
            }
        }
    }

    pub fn deinit(self: *Renderer) void {
        _ = self;
    }
};
