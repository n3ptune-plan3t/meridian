const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;
const Sysfs = @import("sysfs.zig").Sysfs;

const log = std.log.scoped(.widget_battery);

pub const BatteryWidget = struct {
    allocator: Allocator,
    cfg: *const Config,
    capacity: u8,
    status: Sysfs.BatteryStatus,
    bat_name: []const u8,
    visible: bool = true,
    dirty: bool = true,
    buf: [32]u8 = undefined,

    pub fn init(allocator: Allocator, cfg: *const Config) !BatteryWidget {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .capacity = 0,
            .status = .unknown,
            .bat_name = "BAT0",
        };
    }

    pub fn update(self: *BatteryWidget) void {
        const info = Sysfs.readBattery(self.allocator, self.bat_name) catch |err| {
            log.warn("failed to read battery: {}", .{err});
            return;
        };

        if (info.capacity != self.capacity or info.status != self.status) {
            self.capacity = info.capacity;
            self.status = info.status;
            self.dirty = true;
        }
    }

    pub fn render(self: *BatteryWidget, renderer: *Renderer, x: i32, y: i32) i32 {
        if (self.dirty) {
            self.update();
        }

        const icon = switch (self.status) {
            .charging => "󰂄 ",
            .discharging => "󰁹 ",
            .full => "󰂅 ",
            .unknown => "󰂑 ",
        };

        const text = std.fmt.bufPrint(&self.buf, "{s}{d}%", .{ icon, self.capacity }) catch return x;

        const color: u32 = if (self.capacity <= 20)
            0xFFFF6B6B
        else if (self.capacity <= 50)
            0xFFFFD93D
        else
            self.cfg.bar.foreground;

        self.dirty = false;
        return renderer.drawText(x, y, text, color);
    }
};
