const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.pulseaudio);

pub const PulseAudioClient = struct {
    allocator: Allocator,
    fd: ?i32,
    volume: u8,
    muted: bool,
    callback: *const fn (u8, bool, ?*anyopaque) void,
    context: ?*anyopaque,
    tag: u32,

    pub fn init(
        allocator: Allocator,
        callback: *const fn (u8, bool, ?*anyopaque) void,
        context: ?*anyopaque,
    ) !PulseAudioClient {
        const fd = try connectToPulse();
        var client = PulseAudioClient{
            .allocator = allocator,
            .fd = fd,
            .volume = 0,
            .muted = false,
            .callback = callback,
            .context = context,
            .tag = 1,
        };

        try client.setupSubscription();
        return client;
    }

    fn connectToPulse() !i32 {
        const runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse
            return error.NoRuntimeDir;

        const pulse_socket_path = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/pulse/native",
            .{runtime_dir},
        );
        defer std.heap.page_allocator.free(pulse_socket_path);

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        const path_bytes = pulse_socket_path[0..@min(pulse_socket_path.len, addr.path.len - 1)];
        @memcpy(addr.path[0..path_bytes.len], path_bytes);
        addr.path[path_bytes.len] = 0;

        const addr_bytes = std.mem.asBytes(&addr);
        const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un) - addr.path.len + path_bytes.len + 1;

        try posix.connect(fd, @ptrCast(addr_bytes), addr_len);
        return fd;
    }

    fn setupSubscription(self: *PulseAudioClient) !void {
        const fd = self.fd orelse return error.NotConnected;

        const tag = self.tag;
        self.tag += 1;

        var buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "SET_SUBSCRIBE {d}\n", .{tag});
        _ = try posix.write(fd, cmd);

        const sub_cmd = try std.fmt.bufPrint(&buf, "SUBSCRIBE 0x{X:0>8}\n", .{0x0010 | 0x0200 | 0x0004});
        _ = try posix.write(fd, sub_cmd);
    }

    pub fn handleEvent(self: *PulseAudioClient) void {
        const fd = self.fd orelse return;

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch return;
        if (n == 0) return;

        const data = buf[0..@intCast(n)];
        var lines = std.mem.splitSequence(u8, data, "\n");

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "EVENT ")) {
                self.processEvent(line);
            } else if (std.mem.startsWith(u8, line, "BEGIN ")) {
            } else if (std.mem.startsWith(u8, line, "CHANGE ")) {
                self.processChange(line);
            } else if (std.mem.startsWith(u8, line, "REMOVE ")) {
            } else if (std.mem.startsWith(u8, line, "OK ")) {
                self.processOk(line);
            }
        }
    }

    fn processEvent(self: *PulseAudioClient, line: []const u8) void {
        const rest = std.mem.trim(u8, line["EVENT ".len..], " ");
        var parts = std.mem.splitSequence(u8, rest, " ");

        if (parts.next()) |event_type_str| {
            _ = std.fmt.parseInt(u32, event_type_str, 10) catch return;

            if (parts.next()) |index_str| {
                _ = std.fmt.parseInt(u32, index_str, 10) catch return;
                self.requestSinkInfo();
            }
        }
    }

    fn processChange(self: *PulseAudioClient, line: []const u8) void {
        const rest = std.mem.trim(u8, line["CHANGE ".len..], " ");
        var parts = std.mem.splitSequence(u8, rest, " ");

        if (parts.next()) |index_str| {
            _ = std.fmt.parseInt(u32, index_str, 10) catch return;
            self.requestSinkInfo();
        }
    }

    fn processOk(self: *PulseAudioClient, line: []const u8) void {
        const rest = std.mem.trim(u8, line["OK ".len..], " ");
        var parts = std.mem.splitSequence(u8, rest, " ");

        if (parts.next()) |tag_str| {
            _ = std.fmt.parseInt(u32, tag_str, 10) catch return;

            if (parts.next()) |value_str| {
                if (std.fmt.parseInt(u32, value_str, 10)) |volume_raw| {
                    const volume = @min(volume_raw / 100, 100);
                    self.volume = @intCast(volume);
                    self.callback(self.volume, self.muted, self.context);
                } else |_| {}
            }
        }
    }

    fn requestSinkInfo(self: *PulseAudioClient) void {
        const fd = self.fd orelse return;

        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "GET_SINK_INFO 0 default\n", .{}) catch return;
        _ = posix.write(fd, cmd) catch return;
    }

    pub fn getVolume(self: *const PulseAudioClient) struct { volume: u8, muted: bool } {
        return .{ .volume = self.volume, .muted = self.muted };
    }

    pub fn deinit(self: *PulseAudioClient) void {
        if (self.fd) |fd| {
            posix.close(fd);
        }
    }
};
