const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const log = std.log.scoped(.config);

pub const Config = struct {
    bar: BarConfig,
    widgets: WidgetsConfig,
    notifications: NotificationsConfig,
    launcher: LauncherConfig,
    wallpaper: WallpaperConfig,

    pub const BarConfig = struct {
        position: Position = .top,
        height: u32 = 32,
        exclusive_zone: i32 = 32,
        background: u32 = 0xFF1A1B26,
        foreground: u32 = 0xFFC0CAF5,
        font_size: u32 = 13,
        padding: u32 = 8,
    };

    pub const Position = enum {
        top,
        bottom,
        left,
        right,
    };

    pub const WidgetsConfig = struct {
        left: []const []const u8 = &.{},
        center: []const []const u8 = &.{"clock"},
        right: []const []const u8 = &.{ "battery", "volume", "network" },
    };

    pub const NotificationsConfig = struct {
        position: []const u8 = "top-right",
        width: u32 = 300,
        height: u32 = 100,
        timeout: u32 = 5000,
        background: u32 = 0xFF1A1B26,
        foreground: u32 = 0xFFC0CAF5,
        border: u32 = 0xFF7AA2F7,
    };

    pub const LauncherConfig = struct {
        width: u32 = 600,
        height: u32 = 400,
        background: u32 = 0xFF1A1B26,
        foreground: u32 = 0xFFC0CAF5,
        border: u32 = 0xFF7AA2F7,
    };

    pub const WallpaperConfig = struct {
        path: []const u8 = "",
        mode: WallpaperMode = .fill,
    };

    pub const WallpaperMode = enum {
        fill,
        fit,
        stretch,
        center,
        tile,
    };

    pub fn load(allocator: Allocator, path: []const u8) !Config {
        const file = fs.cwd().openFile(path, .{}) catch |err| {
            log.warn("failed to open config file '{s}': {}, using defaults", .{ path, err });
            return getDefault(allocator);
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return parseToml(allocator, content) catch |err| {
            log.warn("failed to parse config: {}, using defaults", .{err});
            return getDefault(allocator);
        };
    }

    fn parseToml(allocator: Allocator, content: []const u8) !Config {
        _ = allocator;
        var config = Config{
            .bar = .{},
            .widgets = .{},
            .notifications = .{},
            .launcher = .{},
            .wallpaper = .{},
        };

        var lines = std.mem.splitSequence(u8, content, "\n");
        var current_section: []const u8 = "";

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                current_section = trimmed[1 .. trimmed.len - 1];
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                try applyConfig(&config, current_section, key, value);
            }
        }

        return config;
    }

    fn applyConfig(config: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, section, "bar")) {
            if (std.mem.eql(u8, key, "position")) {
                if (std.mem.eql(u8, value, "top")) config.bar.position = .top;
                if (std.mem.eql(u8, value, "bottom")) config.bar.position = .bottom;
                if (std.mem.eql(u8, value, "left")) config.bar.position = .left;
                if (std.mem.eql(u8, value, "right")) config.bar.position = .right;
            } else if (std.mem.eql(u8, key, "height")) {
                config.bar.height = std.fmt.parseInt(u32, value, 10) catch 32;
            } else if (std.mem.eql(u8, key, "exclusive_zone")) {
                config.bar.exclusive_zone = std.fmt.parseInt(i32, value, 10) catch 32;
            } else if (std.mem.eql(u8, key, "font_size")) {
                config.bar.font_size = std.fmt.parseInt(u32, value, 10) catch 13;
            } else if (std.mem.eql(u8, key, "padding")) {
                config.bar.padding = std.fmt.parseInt(u32, value, 10) catch 8;
            }
        } else if (std.mem.eql(u8, section, "notifications")) {
            if (std.mem.eql(u8, key, "position")) {
                config.notifications.position = value;
            } else if (std.mem.eql(u8, key, "width")) {
                config.notifications.width = std.fmt.parseInt(u32, value, 10) catch 300;
            } else if (std.mem.eql(u8, key, "timeout")) {
                config.notifications.timeout = std.fmt.parseInt(u32, value, 10) catch 5000;
            }
        } else if (std.mem.eql(u8, section, "launcher")) {
            if (std.mem.eql(u8, key, "width")) {
                config.launcher.width = std.fmt.parseInt(u32, value, 10) catch 600;
            } else if (std.mem.eql(u8, key, "height")) {
                config.launcher.height = std.fmt.parseInt(u32, value, 10) catch 400;
            }
        } else if (std.mem.eql(u8, section, "wallpaper")) {
            if (std.mem.eql(u8, key, "path")) {
                config.wallpaper.path = value;
            } else if (std.mem.eql(u8, key, "mode")) {
                if (std.mem.eql(u8, value, "fill")) config.wallpaper.mode = .fill;
                if (std.mem.eql(u8, value, "fit")) config.wallpaper.mode = .fit;
                if (std.mem.eql(u8, value, "stretch")) config.wallpaper.mode = .stretch;
                if (std.mem.eql(u8, value, "center")) config.wallpaper.mode = .center;
                if (std.mem.eql(u8, value, "tile")) config.wallpaper.mode = .tile;
            }
        } else if (std.mem.eql(u8, section, "widgets")) {
            if (std.mem.eql(u8, key, "left")) {
                config.widgets.left = &.{};
            } else if (std.mem.eql(u8, key, "center")) {
                config.widgets.center = &.{"clock"};
            } else if (std.mem.eql(u8, key, "right")) {
                config.widgets.right = &.{ "battery", "volume", "network" };
            }
        }
    }

    fn getDefault(allocator: Allocator) Config {
        _ = allocator;
        return .{
            .bar = .{},
            .widgets = .{},
            .notifications = .{},
            .launcher = .{},
            .wallpaper = .{},
        };
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};
