const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.sysfs);

pub const InotifyWatcher = struct {
    allocator: Allocator,
    inotify_fd: i32,
    watches: std.AutoHashMap(i32, WatchEntry),
    next_id: u32,

    const WatchEntry = struct {
        path: []const u8,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        context: ?*anyopaque,
    };

    pub fn init(allocator: Allocator) !InotifyWatcher {
        const inotify_fd = linux.inotify_init1(linux.IN_CLOEXEC | linux.IN_NONBLOCK);
        if (inotify_fd < 0) {
            log.err("failed to init inotify: {}", .{errno()});
            return error.InotifyInitFailed;
        }

        return .{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .watches = std.AutoHashMap(i32, WatchEntry).init(allocator),
            .next_id = 0,
        };
    }

    pub fn watch(self: *InotifyWatcher, path: []const u8, callback: *const fn ([]const u8, ?*anyopaque) void, context: ?*anyopaque) !void {
        const mask = linux.IN_MODIFY | linux.IN_CLOSE_WRITE | linux.IN_MOVED_TO;

        const dir_path = if (fs.path.dirname(path)) |d| d else ".";
        const dir = try fs.cwd().openDir(dir_path, .{});
        defer dir.close();

        const wd = linux.inotify_add_watch(self.inotify_fd, @ptrCast(path.ptr), mask);
        if (wd < 0) {
            log.err("inotify_add_watch failed for {s}: {}", .{ path, errno() });
            return error.InotifyWatchFailed;
        }

        try self.watches.put(@intCast(wd), .{
            .path = try self.allocator.dupe(u8, path),
            .callback = callback,
            .context = context,
        });
    }

    pub fn unwatch(self: *InotifyWatcher, wd: i32) void {
        _ = linux.inotify_rm_watch(self.inotify_fd, @intCast(wd));
        if (self.watches.fetchRemove(@intCast(wd))) |kv| {
            self.allocator.free(kv.value.path);
        }
    }

    pub fn handleEvents(self: *InotifyWatcher) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (true) {
            const n = posix.read(self.inotify_fd, &buf) catch break;
            if (n == 0) break;

            var offset: usize = 0;
            while (offset < @as(usize, @intCast(n))) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
                const name: [*:0]const u8 = @ptrCast(&buf[offset + @sizeOf(linux.inotify_event)]);
                const name_slice = std.mem.sliceTo(name, 0);

                if (self.watches.get(@intCast(event.wd))) |entry| {
                    const full_path = if (name_slice.len > 0)
                        std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ entry.path, name_slice }) catch entry.path
                    else
                        entry.path;
                    defer if (name_slice.len > 0) self.allocator.free(full_path);

                    entry.callback(full_path, entry.context);
                }

                offset += @sizeOf(linux.inotify_event) + event.len;
            }
        }
    }

    pub fn deinit(self: *InotifyWatcher) var {
        var iter = self.watches.iterator();
        while (iter.next()) |kv| {
            self.allocator.free(kv.value.path);
        }
        self.watches.deinit();
        posix.close(self.inotify_fd);
    }

    fn errno() posix.E {
        return posix.errno();
    }
};

pub const Sysfs = struct {
    pub fn readFile(allocator: Allocator, path: []const u8) ![]const u8 {
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, 4096);
    }

    pub fn readBattery(allocator: Allocator, bat: []const u8) !BatteryInfo {
        const capacity_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/capacity", .{bat});
        defer allocator.free(capacity_path);

        const status_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/status", .{bat});
        defer allocator.free(status_path);

        const capacity_str = readFile(allocator, capacity_path) catch return error.ReadFailed;
        defer allocator.free(capacity_str);

        const status_str = readFile(allocator, status_path) catch return error.ReadFailed;
        defer allocator.free(status_str);

        const capacity = std.fmt.parseInt(u8, std.mem.trim(u8, capacity_str, "\n"), 10) catch 0;

        const status = if (std.mem.eql(u8, std.mem.trim(u8, status_str, "\n"), "Charging"))
            .charging
        else if (std.mem.eql(u8, std.mem.trim(u8, status_str, "\n"), "Discharging"))
            .discharging
        else if (std.mem.eql(u8, std.mem.trim(u8, status_str, "\n"), "Full"))
            .full
        else
            .unknown;

        return .{ .capacity = capacity, .status = status };
    }

    pub fn readNetwork(allocator: Allocator, iface: []const u8) !NetworkInfo {
        const operstate_path = try std.fmt.allocPrint(allocator, "/sys/class/net/{s}/operstate", .{iface});
        defer allocator.free(operstate_path);

        const operstate_str = readFile(allocator, operstate_path) catch return error.ReadFailed;
        defer allocator.free(operstate_str);

        const state = std.mem.trim(u8, operstate_str, "\n");
        const connected = std.mem.eql(u8, state, "up");

        return .{
            .connected = connected,
            .interface = iface,
        };
    }

    pub const BatteryInfo = struct {
        capacity: u8,
        status: BatteryStatus,
    };

    pub const BatteryStatus = enum {
        charging,
        discharging,
        full,
        unknown,
    };

    pub const NetworkInfo = struct {
        connected: bool,
        interface: []const u8,
    };
};
