const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;

const log = std.log.scoped(.widget_volume);

pub const VolumeWidget = struct {
    allocator: Allocator,
    cfg: *const Config,
    volume: u8,
    muted: bool,
    visible: bool = true,
    dirty: bool = true,
    buf: [32]u8 = undefined,

    pub fn init(allocator: Allocator, cfg: *const Config) !VolumeWidget {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .volume = 0,
            .muted = false,
        };
    }

    pub fn setVolume(self: *VolumeWidget, volume: u8, muted: bool) void {
        if (volume != self.volume or muted != self.muted) {
            self.volume = volume;
            self.muted = muted;
            self.dirty = true;
        }
    }

    pub fn render(self: *VolumeWidget, renderer: *Renderer, x: i32, y: i32) i32 {
        const icon = if (self.muted)
            "󰝟 "
        else if (self.volume == 0)
            "󰕿 "
        else if (self.volume < 33)
            "󰖀 "
        else if (self.volume < 66)
            "󰕾 "
        else
            "󰕾 ";

        const text = std.fmt.bufPrint(&self.buf, "{s}{d}%", .{ icon, self.volume }) catch return x;

        const color: u32 = if (self.muted)
            0xFFFF6B6B
        else
            self.cfg.bar.foreground;

        self.dirty = false;
        return renderer.drawText(x, y, text, color);
    }
};
