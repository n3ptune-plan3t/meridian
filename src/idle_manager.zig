const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("ext-idle-notification-v1-client-protocol.h");
});

const log = std.log.scoped(.idle_manager);

pub const IdleManager = struct {
    notifier: ?*c.ext_idle_notifier_v1,
    notifications: std.ArrayList(IdleNotification),
    callback: ?*const fn (IdleState, ?*anyopaque) void,
    context: ?*anyopaque,

    pub const IdleState = enum {
        active,
        idle,
    };

    pub const IdleNotification = struct {
        notification: ?*c.ext_idle_notification_v1,
        timeout_ms: u32,
        state: IdleState,
    };

    pub fn init(
        notifier: ?*c.ext_idle_notifier_v1,
        callback: *const fn (IdleState, ?*anyopaque) void,
        context: ?*anyopaque,
    ) IdleManager {
        return .{
            .notifier = notifier,
            .notifications = std.ArrayList(IdleNotification).init(std.heap.page_allocator),
            .callback = callback,
            .context = context,
        };
    }

    pub fn requestIdleNotification(self: *IdleManager, seat: ?*c.wl_seat, timeout_ms: u32) void {
        const notifier = self.notifier orelse return;
        const seat_obj = seat orelse return;

        const notification = c.ext_idle_notifier_v1_get_idle_notification(
            notifier,
            seat_obj,
            timeout_ms,
        );

        if (notification) |notif| {
            const idle_data = @as(*IdleData, @ptrCast(c.wl_proxy_get_user_data(@ptrCast(notif)) orelse return));
            idle_data.manager = self;
            idle_data.timeout_ms = timeout_ms;

            c.ext_idle_notification_v1_add_listener(
                notif,
                &idle_notification_listener,
                @ptrCast(idle_data),
            );

            self.notifications.append(.{
                .notification = notif,
                .timeout_ms = timeout_ms,
                .state = .active,
            }) catch return;
        }
    }

    pub fn cancelIdleNotification(self: *IdleManager, timeout_ms: u32) void {
        var i: usize = 0;
        while (i < self.notifications.items.len) {
            if (self.notifications.items[i].timeout_ms == timeout_ms) {
                if (self.notifications.items[i].notification) |notif| {
                    c.ext_idle_notification_v1_destroy(notif);
                }
                _ = self.notifications.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn handleIdle(self: *IdleManager, timeout_ms: u32) void {
        for (self.notifications.items) |*notif| {
            if (notif.timeout_ms == timeout_ms) {
                notif.state = .idle;
                break;
            }
        }

        if (self.callback) |cb| {
            cb(.idle, self.context);
        }
    }

    pub fn handleActive(self: *IdleManager, timeout_ms: u32) void {
        for (self.notifications.items) |*notif| {
            if (notif.timeout_ms == timeout_ms) {
                notif.state = .active;
                break;
            }
        }

        if (self.callback) |cb| {
            cb(.active, self.context);
        }
    }

    pub fn isActive(self: *const IdleManager) bool {
        for (self.notifications.items) |notif| {
            if (notif.state == .idle) return false;
        }
        return true;
    }

    pub fn deinit(self: *IdleManager) void {
        for (self.notifications.items) |notif| {
            if (notif.notification) |notif_obj| {
                c.ext_idle_notification_v1_destroy(notif_obj);
            }
        }
        self.notifications.deinit();
    }
};

const IdleData = struct {
    manager: *IdleManager,
    timeout_ms: u32,
};

const idle_notification_listener = c.ext_idle_notification_v1_listener{
    .idled = onIdle,
    .resumed = onResumed,
};

fn onIdle(data: ?*anyopaque, notification: ?*c.ext_idle_notification_v1) callconv(.c) void {
    _ = notification;
    const idle_data: *IdleData = @ptrCast(@alignCast(data orelse return));
    idle_data.manager.handleIdle(idle_data.timeout_ms);
}

fn onResumed(data: ?*anyopaque, notification: ?*c.ext_idle_notification_v1) callconv(.c) void {
    _ = notification;
    const idle_data: *IdleData = @ptrCast(@alignCast(data orelse return));
    idle_data.manager.handleActive(idle_data.timeout_ms);
}
