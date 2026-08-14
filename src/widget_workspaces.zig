const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const Renderer = @import("render.zig").Renderer;
const NiriIpc = @import("niri_ipc.zig").NiriIpc;

const log = std.log.scoped(.widget_workspaces);

pub const WorkspacesWidget = struct {
    cfg: *const Config,
    workspaces: std.ArrayList(Workspace),
    focused_id: ?u32,
    visible: bool = true,
    dirty: bool = true,

    pub const Workspace = struct {
        id: u32,
        name: ?[]const u8,
        output: ?[]const u8,
        is_active: bool,
        is_focused: bool,
    };

    pub fn init(cfg: *const Config) WorkspacesWidget {
        return .{
            .cfg = cfg,
            .workspaces = std.ArrayList(Workspace).init(std.heap.page_allocator),
            .focused_id = null,
        };
    }

    pub fn updateFromIpc(self: *WorkspacesWidget, niri: *NiriIpc) void {
        self.workspaces.clearRetainingCapacity();

        for (niri.workspaces.items) |ws| {
            self.workspaces.append(.{
                .id = ws.id,
                .name = ws.name,
                .output = ws.output,
                .is_active = ws.is_active,
                .is_focused = ws.is_focused,
            }) catch continue;

            if (ws.is_focused) {
                self.focused_id = ws.id;
            }
        }

        self.dirty = true;
    }

    pub fn render(self: *WorkspacesWidget, renderer: *Renderer, x: i32, y: i32) i32 {
        var cursor = x;

        for (self.workspaces.items, 0..) |ws, i| {
            _ = i;
            const is_focused = ws.is_focused;
            const is_active = ws.is_active;

            const color: u32 = if (is_focused)
                self.cfg.bar.foreground
            else if (is_active)
                0xFF7AA2F7
            else
                0xFF565F89;

            const text = if (ws.name) |name|
                std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{name}) catch continue
            else
                std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{ws.id}) catch continue;
            defer std.heap.page_allocator.free(text);

            if (is_focused) {
                renderer.fillRect(cursor - 2, y - 2, @intCast(text.len * 8 + 8), @intCast(self.cfg.bar.font_size + 4), 0xFF7AA2F7);
            }

            cursor = renderer.drawText(cursor, y, text, color);
            cursor += 8;
        }

        self.dirty = false;
        return cursor;
    }
};
