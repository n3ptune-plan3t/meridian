const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
});

const Config = @import("config.zig").Config;

const log = std.log.scoped(.layer_shell);

pub const BarSurface = struct {
    wl_surface: *c.wl_surface,
    layer_surface: *c.zwlr_layer_surface_v1,
    wl_shm_pool: ?*c.wl_shm_pool,
    buffer: ?*c.wl_buffer,
    width: u32,
    height: u32,
    configured: bool,

    pub fn init(
        compositor: *c.wl_compositor,
        layer_shell: *c.zwlr_layer_shell_v1,
        shm: *c.wl_shm,
        cfg: *const Config,
    ) !BarSurface {
        const surface = c.wl_compositor_create_surface(compositor) orelse {
            log.err("failed to create surface", .{});
            return error.CreateSurfaceFailed;
        };

        const output: ?*c.wl_output = null;

        const layer: u32 = switch (cfg.bar.position) {
            .top, .bottom => c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            .left, .right => c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        };

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            surface,
            output,
            layer,
            "meridian-bar",
        ) orelse {
            c.wl_surface_destroy(surface);
            log.err("failed to create layer surface", .{});
            return error.CreateLayerSurfaceFailed;
        };

        const anchor: u32 = switch (cfg.bar.position) {
            .top => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
            .bottom => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
            .left => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
            .right => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
        };

        c.zwlr_layer_surface_v1_set_anchor(layer_surface, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, @intCast(cfg.bar.height));
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, @intCast(cfg.bar.exclusive_zone));
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(layer_surface, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        c.zwlr_layer_surface_v1_set_margin(layer_surface, 0, 0, 0, 0);
        c.zwlr_layer_surface_v1_set_layer(layer_surface, layer);

        const data = @as([*]u8, @ptrCast(cfg));
        _ = data;
        c.wl_surface_commit(surface);

        return .{
            .wl_surface = surface,
            .layer_surface = layer_surface,
            .wl_shm_pool = null,
            .buffer = null,
            .width = 1920,
            .height = cfg.bar.height,
            .configured = false,
        };
    }

    pub fn createBuffer(self: *BarSurface, shm: *c.wl_shm, pool_fd: i32, pool_size: i32) !void {
        if (self.wl_shm_pool) |pool| {
            c.wl_shm_pool_destroy(pool);
        }

        const pool = c.wl_shm_create_pool(shm, pool_fd, pool_size) orelse {
            log.err("failed to create shm pool", .{});
            return error.CreatePoolFailed;
        };

        const buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(self.width),
            @intCast(self.height),
            @intCast(self.width * 4),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse {
            c.wl_shm_pool_destroy(pool);
            log.err("failed to create buffer", .{});
            return error.CreateBufferFailed;
        };

        self.wl_shm_pool = pool;
        self.buffer = buffer;
    }

    pub fn attachAndCommit(self: *BarSurface) void {
        if (self.buffer) |buf| {
            c.wl_surface_attach(self.wl_surface, buf, 0, 0);
            c.wl_surface_damage_buffer(self.wl_surface, 0, 0, @intCast(self.width), @intCast(self.height));
            c.wl_surface_commit(self.wl_surface);
        }
    }

    pub fn deinit(self: *BarSurface) void {
        if (self.buffer) |buf| {
            c.wl_buffer_destroy(buf);
        }
        if (self.wl_shm_pool) |pool| {
            c.wl_shm_pool_destroy(pool);
        }
        c.zwlr_layer_surface_v1_destroy(self.layer_surface);
        c.wl_surface_destroy(self.wl_surface);
    }
};
