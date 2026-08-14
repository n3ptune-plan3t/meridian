const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
});

const log = std.log.scoped(.output);

pub const OutputInfo = struct {
    id: u32,
    name: ?[]const u8,
    description: ?[]const u8,
    width: i32,
    height: i32,
    refresh: i32,
    scale: i32,
    transform: i32,
    x: i32,
    y: i32,

    pub fn init(id: u32) OutputInfo {
        return .{
            .id = id,
            .name = null,
            .description = null,
            .width = 1920,
            .height = 1080,
            .refresh = 60000,
            .scale = 1,
            .transform = 0,
            .x = 0,
            .y = 0,
        };
    }
};

pub const OutputManager = struct {
    allocator: std.mem.Allocator,
    outputs: std.ArrayList(OutputInfo),

    pub fn init(allocator: std.mem.Allocator) OutputManager {
        return .{
            .allocator = allocator,
            .outputs = std.ArrayList(OutputInfo).init(allocator),
        };
    }

    pub fn addOutput(self: *OutputManager, id: u32) !*OutputInfo {
        const info = try self.outputs.addOne();
        info.* = OutputInfo.init(id);
        return info;
    }

    pub fn removeOutput(self: *OutputManager, id: u32) void {
        var i: usize = 0;
        while (i < self.outputs.items.len) {
            if (self.outputs.items[i].id == id) {
                _ = self.outputs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn findById(self: *OutputManager, id: u32) ?*OutputInfo {
        for (self.outputs.items) |*info| {
            if (info.id == id) return info;
        }
        return null;
    }

    pub fn getPrimary(self: *OutputManager) ?*OutputInfo {
        if (self.outputs.items.len == 0) return null;
        return &self.outputs.items[0];
    }

    pub fn deinit(self: *OutputManager) void {
        self.outputs.deinit();
    }
};
