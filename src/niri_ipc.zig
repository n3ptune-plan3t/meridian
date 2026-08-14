const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.niri_ipc);

pub const NiriIpc = struct {
    allocator: Allocator,
    fd: ?i32,
    socket_path: ?[]const u8,
    workspaces: std.ArrayList(Workspace),
    focused_workspace_id: ?u32,

    pub const Workspace = struct {
        id: u32,
        name: ?[]const u8,
        output: ?[]const u8,
        is_active: bool,
        is_focused: bool,
        active_window_id: ?u32,
    };

    pub fn init(allocator: Allocator) !NiriIpc {
        const socket_path = std.posix.getenv("NIRI_SOCKET");

        const path = if (socket_path) |p| try allocator.dupe(u8, p) else null;

        const fd = if (path) |p| blk: {
            break :blk connectToSocket(p) catch |err| {
                log.warn("failed to connect to niri socket: {}", .{err});
                null;
            };
        } else null;

        return .{
            .allocator = allocator,
            .fd = fd,
            .socket_path = path,
            .workspaces = std.ArrayList(Workspace).init(allocator),
            .focused_workspace_id = null,
        };
    }

    fn connectToSocket(path: []const u8) !i32 {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch {
            return error.SocketFailed;
        };
        errdefer posix.close(fd);

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        const path_bytes = path[0..@min(path.len, addr.path.len - 1)];
        @memcpy(addr.path[0..path_bytes.len], path_bytes);
        addr.path[path_bytes.len] = 0;

        const addr_bytes = std.mem.asBytes(&addr);
        const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un) - addr.path.len + path_bytes.len + 1;

        posix.connect(fd, @ptrCast(addr_bytes), addr_len) catch {
            return error.ConnectFailed;
        };

        return fd;
    }

    pub fn request(self: *NiriIpc, request: []const u8) ![]const u8 {
        const fd = self.fd orelse return error.NotConnected;

        const msg = try std.fmt.allocPrint(self.allocator, "{s}\n", .{request});
        defer self.allocator.free(msg);

        _ = posix.write(fd, msg) catch {
            return error.WriteFailed;
        };

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch {
            return error.ReadFailed;
        };

        if (n == 0) return error.ConnectionClosed;

        return try self.allocator.dupe(u8, buf[0..n]);
    }

    pub fn getWorkspaces(self: *NiriIpc) ![]Workspace {
        _ = try self.request("Workspaces");
        return self.workspaces.items;
    }

    pub fn subscribe(self: *NiriIpc) !void {
        _ = try self.request("EventStream");
    }

    pub fn deinit(self: *NiriIpc) void {
        self.workspaces.deinit();
        if (self.fd) |fd| {
            posix.close(fd);
        }
        if (self.socket_path) |path| {
            self.allocator.free(path);
        }
    }
};
