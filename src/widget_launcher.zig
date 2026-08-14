const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const log = std.log.scoped(.widget_launcher);

pub const LauncherWidget = struct {
    allocator: Allocator,
    cfg: *const Config,
    visible: bool = false,
    dirty: bool = true,
    search_buf: [256]u8 = undefined,
    search_len: usize = 0,
    results: std.ArrayList(AppEntry),
    selected: usize = 0,

    pub const AppEntry = struct {
        name: []const u8,
        exec: []const u8,
        desktop_file: []const u8,
    };

    pub fn init(allocator: Allocator, cfg: *const Config, compositor: ?*c.wl_compositor, wm_base: ?*c.xdg_wm_base) LauncherWidget {
        _ = compositor;
        _ = wm_base;
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .results = std.ArrayList(AppEntry).init(allocator),
        };
    }

    pub fn toggle(self: *LauncherWidget) void {
        self.visible = !self.visible;
        self.dirty = true;
        if (self.visible) {
            self.search_len = 0;
            self.selected = 0;
            self.scanDesktopFiles();
        }
    }

    fn scanDesktopFiles(self: *LauncherWidget) void {
        self.results.clearRetainingCapacity();

        const data_dirs = [_][]const u8{
            "/usr/share/applications",
            "/usr/local/share/applications",
            "/home",
        };

        for (data_dirs) |dir| {
            self.scanDirectory(dir) catch continue;
        }
    }

    fn scanDirectory(self: *LauncherWidget, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer self.allocator.free(path);

            const content = std.fs.cwd().readFileAlloc(self.allocator, path, 4096) catch continue;
            defer self.allocator.free(content);

            var name: ?[]const u8 = null;
            var exec: ?[]const u8 = null;

            var lines = std.mem.splitSequence(u8, content, "\n");
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "Name=")) {
                    name = line[5..];
                } else if (std.mem.startsWith(u8, line, "Exec=")) {
                    exec = line[5..];
                }
            }

            if (name != null and exec != null) {
                self.results.append(.{
                    .name = name.?,
                    .exec = exec.?,
                    .desktop_file = entry.name,
                }) catch continue;
            }
        }
    }

    pub fn handleInput(self: *LauncherWidget, key: u32, utf8: []const u8) void {
        if (!self.visible) return;

        switch (key) {
            0xff1b => { // Escape
                self.visible = false;
                self.dirty = true;
            },
            0xff0d, 0xff8d => { // Return, KP_Enter
                if (self.results.items.len > 0 and self.selected < self.results.items.len) {
                    self.launchApp(self.results.items[self.selected]);
                    self.visible = false;
                    self.dirty = true;
                }
            },
            0xff52, 0xff51 => { // Up, Left
                if (self.selected > 0) {
                    self.selected -= 1;
                    self.dirty = true;
                }
            },
            0xff54, 0xff53 => { // Down, Right
                if (self.selected < self.results.items.len - 1) {
                    self.selected += 1;
                    self.dirty = true;
                }
            },
            0xff08 => { // BackSpace
                if (self.search_len > 0) {
                    self.search_len -= 1;
                    self.dirty = true;
                    self.filterResults();
                }
            },
            else => {
                if (utf8.len > 0 and self.search_len < self.search_buf.len - 1) {
                    @memcpy(self.search_buf[self.search_len .. self.search_len + utf8.len], utf8);
                    self.search_len += utf8.len;
                    self.dirty = true;
                    self.filterResults();
                }
            },
        }
    }

    fn filterResults(self: *LauncherWidget) void {
        if (self.search_len == 0) {
            self.scanDesktopFiles();
            return;
        }

        const query = self.search_buf[0..self.search_len];
        var filtered = std.ArrayList(AppEntry).init(self.allocator);

        for (self.results.items) |entry| {
            if (std.mem.indexOf(u8, entry.name, query) != null) {
                filtered.append(entry) catch continue;
            }
        }

        self.results.deinit();
        self.results = filtered;
        self.selected = 0;
    }

    fn launchApp(self: *LauncherWidget, app: AppEntry) void {
        const command = std.fmt.allocPrint(self.allocator, "{s} &", .{app.exec}) catch return;
        defer self.allocator.free(command);

        const argv = [_][]const u8{ "sh", "-c", command };
        _ = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
        }) catch |err| {
            log.warn("failed to launch app: {}", .{err});
        };
    }

    pub fn render(self: *LauncherWidget, renderer: *Renderer, screen_width: i32, screen_height: i32) void {
        if (!self.visible) return;

        const launcher_width: i32 = @intCast(self.cfg.launcher.width);
        const launcher_height: i32 = @intCast(self.cfg.launcher.height);
        const x = (screen_width - launcher_width) / 2;
        const y = (screen_height - launcher_height) / 2;

        renderer.fillRect(x, y, launcher_width, launcher_height, self.cfg.launcher.background);
        renderer.fillRect(x, y, launcher_width, 2, self.cfg.launcher.border);

        const search_y = y + 16;
        renderer.fillRect(x + 16, search_y, launcher_width - 32, 32, 0xFF24283B);

        if (self.search_len > 0) {
            _ = renderer.drawText(x + 24, search_y + 6, self.search_buf[0..self.search_len], self.cfg.launcher.foreground);
        }

        var list_y = search_y + 48;
        const max_visible = @min(self.results.items.len, 8);

        var i: usize = 0;
        while (i < max_visible) : (i += 1) {
            const entry = self.results.items[i];
            const is_selected = i == self.selected;

            if (is_selected) {
                renderer.fillRect(x + 16, list_y - 4, launcher_width - 32, 28, 0xFF7AA2F7);
            }

            const color = if (is_selected) 0xFF1A1B26 else self.cfg.launcher.foreground;
            _ = renderer.drawText(x + 24, list_y, entry.name, color);

            list_y += 32;
        }

        self.dirty = false;
    }
};
