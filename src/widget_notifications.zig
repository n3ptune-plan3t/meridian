const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;

const log = std.log.scoped(.widget_notifications);

pub const NotificationsWidget = struct {
    allocator: Allocator,
    cfg: *const Config,
    notifications: std.ArrayList(Notification),
    visible: bool = false,
    dirty: bool = true,

    pub const Notification = struct {
        app_name: []const u8,
        summary: []const u8,
        body: ?[]const u8,
        urgency: Urgency,
        timestamp: i64,
        id: u32,

        pub const Urgency = enum {
            low,
            normal,
            critical,
        };
    };

    pub fn init(allocator: Allocator, cfg: *const Config) NotificationsWidget {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .notifications = std.ArrayList(Notification).init(allocator),
        };
    }

    pub fn addNotification(self: *NotificationsWidget, notif: Notification) !void {
        try self.notifications.append(notif);
        self.visible = true;
        self.dirty = true;
    }

    pub fn removeNotification(self: *NotificationsWidget, id: u32) void {
        var i: usize = 0;
        while (i < self.notifications.items.len) {
            if (self.notifications.items[i].id == id) {
                _ = self.notifications.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        if (self.notifications.items.len == 0) {
            self.visible = false;
        }
        self.dirty = true;
    }

    pub fn render(self: *NotificationsWidget, renderer: *Renderer, screen_width: i32, screen_height: i32) void {
        if (!self.visible or self.notifications.items.len == 0) return;

        const notif_width: i32 = @intCast(self.cfg.notifications.width);
        const notif_height: i32 = 80;
        const margin: i32 = 10;

        var y_offset: i32 = margin;

        for (self.notifications.items) |notif| {
            const x = screen_width - notif_width - margin;
            const y = y_offset;

            renderer.fillRect(x, y, notif_width, notif_height, self.cfg.notifications.background);
            renderer.fillRect(x, y, 4, notif_height, self.cfg.notifications.border);

            _ = renderer.drawText(x + 12, y + 10, notif.app_name, 0xFF7AA2F7);
            _ = renderer.drawText(x + 12, y + 30, notif.summary, self.cfg.notifications.foreground);

            if (notif.body) |body| {
                const max_chars = @min(body.len, @as(usize, @intCast((notif_width - 24) / 8)));
                _ = renderer.drawText(x + 12, y + 50, body[0..max_chars], 0xFF565F89);
            }

            y_offset += notif_height + margin;
        }

        self.dirty = false;
    }
};
