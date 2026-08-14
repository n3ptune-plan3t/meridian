const std = @import("std");
const time = std.time;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;

const log = std.log.scoped(.widget_clock);

pub const ClockWidget = struct {
    cfg: *const Config,
    last_minute: i64 = -1,
    buf: [32]u8 = undefined,
    visible: bool = true,
    dirty: bool = true,

    pub fn init(cfg: *const Config) ClockWidget {
        return .{ .cfg = cfg };
    }

    pub fn update(self: *ClockWidget) ?[]const u8 {
        const timestamp = time.timestamp();
        const epoch_seconds = @divTrunc(timestamp, time.s_per_min);
        if (epoch_seconds == self.last_minute) return null;
        self.last_minute = epoch_seconds;
        self.dirty = true;

        const secs = @as(u64, @intCast(timestamp));
        const mins = @divTrunc(secs, 60);
        const hours = @divTrunc(mins, 60);
        const m = mins % 60;
        const h = hours % 24;

        const str = std.fmt.bufPrint(&self.buf, "{d:0>2}:{d:0>2}", .{ h, m }) catch return null;
        return str;
    }

    pub fn render(self: *ClockWidget, renderer: *Renderer, x: i32, y: i32) i32 {
        if (self.update()) |text| {
            return renderer.drawText(x, y, text, self.cfg.bar.foreground);
        }
        return x;
    }
};
