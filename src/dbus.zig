const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.dbus);

pub const DbusClient = struct {
    allocator: Allocator,
    fd: ?i32,
    connected: bool,
    callback: *const fn (DbusSignal, ?*anyopaque) void,
    context: ?*anyopaque,
    serial: u32,

    pub const DbusSignal = enum {
        network_up,
        network_down,
        network_changed,
    };

    pub fn init(
        allocator: Allocator,
        callback: *const fn (DbusSignal, ?*anyopaque) void,
        context: ?*anyopaque,
    ) !DbusClient {
        const fd = try connectToDbus();
        var client = DbusClient{
            .allocator = allocator,
            .fd = fd,
            .connected = false,
            .callback = callback,
            .context = context,
            .serial = 1,
        };

        try client.hello();
        try client.subscribeNetworkManager();
        return client;
    }

    fn connectToDbus() !i32 {
        const runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse
            return error.NoRuntimeDir;

        const dbus_path = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/bus",
            .{runtime_dir},
        );
        defer std.heap.page_allocator.free(dbus_path);

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        const path_bytes = dbus_path[0..@min(dbus_path.len, addr.path.len - 1)];
        @memcpy(addr.path[0..path_bytes.len], path_bytes);
        addr.path[path_bytes.len] = 0;

        const addr_bytes = std.mem.asBytes(&addr);
        const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un) - addr.path.len + path_bytes.len + 1;

        try posix.connect(fd, @ptrCast(addr_bytes), addr_len);
        return fd;
    }

    fn hello(self: *DbusClient) !void {
        const fd = self.fd orelse return error.NotConnected;

        const serial = self.serial;
        self.serial += 1;

        var msg: [16]u8 = undefined;
        msg[0] = 'l';
        msg[1] = 0x00;
        msg[2] = 0x01;
        msg[3] = 0x00;
        std.mem.writeInt(u32, msg[4..8], 0, .little);
        std.mem.writeInt(u32, msg[8..12], 0, .little);
        std.mem.writeInt(u32, msg[12..16], serial, .little);

        _ = try posix.write(fd, &msg);

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch return;
        if (n >= 16) {
            self.connected = true;
        }
    }

    fn subscribeNetworkManager(self: *DbusClient) !void {
        const fd = self.fd orelse return error.NotConnected;

        const match_rule = "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'";
        const rule_len = match_rule.len;

        const header_len: u32 = 12 + 16 + 8 + @intCast(rule_len + 1);
        const body_len: u32 = 0;

        var msg: [12 + 16 + 8 + 256]u8 = undefined;
        msg[0] = 'l';
        msg[1] = 0x00;
        msg[2] = 0x02;
        msg[3] = 0x00;
        std.mem.writeInt(u32, msg[4..8], body_len, .little);
        std.mem.writeInt(u32, msg[8..12], self.serial, .little);
        self.serial += 1;

        msg[12] = 0x06;
        msg[13] = 's';
        msg[14] = 0x00;
        @memcpy(msg[15 .. 15 + rule_len], match_rule);
        msg[15 + rule_len] = 0;

        const padding_start = 15 + rule_len + 1;
        const aligned_start = std.mem.alignForward(usize, padding_start, 8);
        @memset(msg[padding_start..aligned_start], 0);

        std.mem.writeInt(u32, msg[aligned_start .. aligned_start + 4], header_len, .little);
        std.mem.writeInt(u32, msg[aligned_start + 4 .. aligned_start + 8], body_len, .little);

        _ = try posix.write(fd, msg[0 .. aligned_start + 8]);
    }

    pub fn handleEvent(self: *DbusClient) void {
        const fd = self.fd orelse return;

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch return;
        if (n == 0) return;

        const data = buf[0..@intCast(n)];
        if (data.len < 16) return;

        if (data[0] != 'l') return;

        const msg_type = data[2];
        if (msg_type != 0x04) return;

        const body_len = std.mem.readInt(u32, data[4..8], .little);
        if (data.len < 16 + body_len) return;

        const header_len = std.mem.readInt(u32, data[8..12], .little);
        const serial = std.mem.readInt(u32, data[12..16], .little);
        _ = serial;

        var offset: usize = 16;
        const header_end = @min(header_len, data.len);

        while (offset + 2 < header_end) {
            const field_code = data[offset];
            offset += 1;

            switch (field_code) {
                0x06 => {
                    if (offset + 1 < header_end and data[offset] == 's') {
                        offset += 1;
                        while (offset < header_end and data[offset] != 0) {
                            offset += 1;
                        }
                        offset += 1;
                        offset = std.mem.alignForward(usize, offset, 4);
                    }
                },
                0x05 => {
                    offset += 4;
                },
                0x08 => {
                    offset += 4;
                },
                0x09 => {
                    offset += 8;
                },
                0x0a => {
                    offset += 1;
                    if (offset < header_end) {
                        const sig_len = data[offset];
                        offset += 1;
                        offset += sig_len;
                        offset = std.mem.alignForward(usize, offset, 4);
                    }
                },
                0x07 => {
                    offset += 4;
                },
                else => {
                    offset = header_end;
                },
            }
        }

        if (self.findStateChange(data[offset .. 16 + body_len])) |state| {
            if (state == 70 or state == 100) {
                self.callback(.network_changed, self.context);
            } else if (state == 10 or state == 20) {
                self.callback(.network_down, self.context);
            } else if (state == 30 or state == 40 or state == 50) {
                self.callback(.network_up, self.context);
            }
        }
    }

    fn findStateChange(self: *DbusClient, body: []const u8) ?u32 {
        _ = self;
        if (body.len < 4) return null;

        const state = std.mem.readInt(u32, body[0..4], .little);
        return state;
    }

    pub fn deinit(self: *DbusClient) void {
        if (self.fd) |fd| {
            posix.close(fd);
        }
    }
};
