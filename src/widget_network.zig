const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;

const log = std.log.scoped(.widget_network);

pub const NetworkWidget = struct {
    allocator: Allocator,
    cfg: *const Config,
    connected: bool,
    interface_name: []const u8,
    visible: bool = true,
    dirty: bool = true,
    buf: [64]u8 = undefined,

    pub fn init(allocator: Allocator, cfg: *const Config) !NetworkWidget {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .connected = false,
            .interface_name = "wlan0",
        };
    }

    pub fn setConnected(self: *NetworkWidget, connected: bool) void {
        if (connected != self.connected) {
            self.connected = connected;
            self.dirty = true;
        }
    }

    pub fn render(self: *NetworkWidget, renderer: *Renderer, x: i32, y: i32) i32 {
        const icon = if (self.connected) "󰤨 " else "󰤭 ";

        const text = if (self.connected)
            std.fmt.bufPrint(&self.buf, "{s}Connected", .{icon}) catch return x
        else
            std.fmt.bufPrint(&self.buf, "{s}Disconnected", .{icon}) catch return x;

        const color: u32 = if (self.connected)
            self.cfg.bar.foreground
        else
            0xFFFF6B6B;

        self.dirty = false;
        return renderer.drawText(x, y, text, color);
    }
};
