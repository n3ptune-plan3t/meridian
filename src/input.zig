const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("linux/input-event-codes.h");
});

const log = std.log.scoped(.input);

pub const InputState = struct {
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: u32 = 0,
    keyboard_focused: bool = false,
    focused_surface: ?*c.wl_surface = null,

    pub fn init() InputState {
        return .{};
    }

    pub fn isButtonPressed(self: *const InputState, button: u32) bool {
        return (self.pointer_buttons & (1 << button)) != 0;
    }

    pub fn setButton(self: *InputState, button: u32, pressed: bool) void {
        if (pressed) {
            self.pointer_buttons |= 1 << button;
        } else {
            self.pointer_buttons &= ~(1 << button);
        }
    }
};

pub const KeyEvent = struct {
    sym: u32,
    utf8: [8]u8,
    utf8_len: u8,
    pressed: bool,
    time: u32,

    pub fn getUtf8(self: *const KeyEvent) []const u8 {
        return self.utf8[0..self.utf8_len];
    }
};

pub const PointerEvent = struct {
    x: f64,
    y: f64,
    button: ?u32,
    pressed: bool,
    time: u32,
    axis: ?AxisEvent,

    pub const AxisEvent = struct {
        axis: u32,
        value: f64,
    };
};
