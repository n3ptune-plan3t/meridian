const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const c = @cImport({
    @cInclude("wayland-client.h");
});

const log = std.log.scoped(.widget_wallpaper);

pub const WallpaperWidget = struct {
    allocator: Allocator,
    compositor: ?*c.wl_compositor,
    shm: ?*c.wl_shm,
    cfg: *const Config,
    surface: ?*c.wl_surface,
    visible: bool = true,
    dirty: bool = true,

    pub fn init(allocator: Allocator, compositor: ?*c.wl_compositor, shm: ?*c.wl_shm, cfg: *const Config) !WallpaperWidget {
        const surface = if (compositor) |comp|
            c.wl_compositor_create_surface(comp)
        else
            null;

        return .{
            .allocator = allocator,
            .compositor = compositor,
            .shm = shm,
            .cfg = cfg,
            .surface = surface,
        };
    }

    pub fn render(self: *WallpaperWidget, renderer: anytype, screen_width: i32, screen_height: i32) void {
        if (!self.visible) return;

        const bg_color = 0xFF1A1B26;
        renderer.fillRect(0, 0, screen_width, screen_height, bg_color);

        if (self.cfg.wallpaper.path.len > 0) {
            log.info("wallpaper path: {s}", .{self.cfg.wallpaper.path});
        }

        self.dirty = false;
    }

    pub fn deinit(self: *WallpaperWidget) void {
        if (self.surface) |surface| {
            c.wl_surface_destroy(surface);
        }
    }
};
