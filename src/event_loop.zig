const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.event_loop);

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    epoll_fd: i32,
    callbacks: std.AutoHashMap(i32, Callback),

    pub const Callback = struct {
        handler: *const fn (i32, u32, ?*anyopaque) void,
        context: ?*anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        const epoll_fd = linux.epoll_create1(linux.EPOLL_CLOEXEC);
        if (epoll_fd < 0) {
            log.err("failed to create epoll: {}", .{errno()});
            return error.EpollCreateFailed;
        }

        return .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .callbacks = std.AutoHashMap(i32, Callback).init(allocator),
        };
    }

    pub fn add(self: *EventLoop, fd: i32, events: u32, handler: *const fn (i32, u32, ?*anyopaque) void, context: ?*anyopaque) !void {
        var event = linux.epoll_event{ .events = events, .data = .{ .fd = fd } };

        if (linux.epoll_ctl(self.epoll_fd, linux.EPOLL_CTL_ADD, fd, &event) < 0) {
            log.err("epoll_ctl add failed for fd {}: {}", .{ fd, errno() });
            return error.EpollCtlFailed;
        }

        try self.callbacks.put(fd, .{ .handler = handler, .context = context });
    }

    pub fn remove(self: *EventLoop, fd: i32) void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL_CTL_DEL, fd, null);
        _ = self.callbacks.remove(fd);
    }

    pub fn dispatch(self: *EventLoop) !void {
        var events: [64]linux.epoll_event = undefined;
        const n = linux.epoll_wait(self.epoll_fd, &events, 64, -1);

        if (n < 0) {
            const err = errno();
            if (err == .INTR) return;
            log.err("epoll_wait failed: {}", .{err});
            return error.EpollWaitFailed;
        }

        for (events[0..@intCast(n)]) |event| {
            const fd = event.data.fd;
            if (self.callbacks.get(fd)) |cb| {
                cb.handler(fd, event.events, cb.context);
            }
        }
    }

    pub fn deinit(self: *EventLoop) void {
        self.callbacks.deinit();
        posix.close(self.epoll_fd);
    }

    fn errno() posix.E {
        return posix.errno();
    }
};
