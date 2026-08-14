const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("freetype2/ft2build.h");
    @cInclude("freetype2/freetype.h");
});

const Config = @import("config.zig").Config;
const EventLoop = @import("event_loop.zig").EventLoop;
const InotifyWatcher = @import("sysfs.zig").InotifyWatcher;
const Sysfs = @import("sysfs.zig").Sysfs;
const PulseAudioClient = @import("pulseaudio.zig").PulseAudioClient;
const DbusClient = @import("dbus.zig").DbusClient;
const NiriIpc = @import("niri_ipc.zig").NiriIpc;
const ShmPool = @import("shm.zig").ShmPool;
const Renderer = @import("render.zig").Renderer;
const FontAtlas = @import("font.zig").FontAtlas;
const BarSurface = @import("layer_shell.zig").BarSurface;
const IdleManager = @import("idle_manager.zig").IdleManager;

const ClockWidget = @import("widget_clock.zig").ClockWidget;
const BatteryWidget = @import("widget_battery.zig").BatteryWidget;
const VolumeWidget = @import("widget_volume.zig").VolumeWidget;
const NetworkWidget = @import("widget_network.zig").NetworkWidget;
const WorkspacesWidget = @import("widget_workspaces.zig").WorkspacesWidget;
const NotificationsWidget = @import("widget_notifications.zig").NotificationsWidget;
const LauncherWidget = @import("widget_launcher.zig").LauncherWidget;
const WallpaperWidget = @import("widget_wallpaper.zig").WallpaperWidget;

const log = std.log.scoped(.main);

var g_app: ?*App = null;

const App = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    event_loop: EventLoop,
    inotify: InotifyWatcher,
    wayland_display: ?*c.wl_display,
    wayland_fd: i32,
    bar: BarSurface,
    shm_pool: ShmPool,
    renderer: Renderer,
    font_atlas: FontAtlas,
    clock: ClockWidget,
    battery: BatteryWidget,
    volume: VolumeWidget,
    network: NetworkWidget,
    workspaces: WorkspacesWidget,
    notifications: NotificationsWidget,
    launcher: LauncherWidget,
    wallpaper: WallpaperWidget,
    niri: NiriIpc,
    pulse: ?PulseAudioClient,
    dbus: ?DbusClient,
    idle: ?IdleManager,
    needs_redraw: bool,
    battery_path: [64]u8,
    network_path: [64]u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = try Config.load(allocator, "config/meridian.toml");
    defer cfg.deinit(allocator);

    var display = c.wl_display_connect(null) orelse {
        log.err("failed to connect to wayland display", .{});
        return error.ConnectionFailed;
    };
    defer c.wl_display_disconnect(display);

    var globals = Globals{};

    const registry = c.wl_display_get_registry(display);
    c.wl_registry_add_listener(registry, &registry_listener, &globals);
    _ = c.wl_display_roundtrip(display);

    if (globals.compositor == null or globals.shm == null or globals.layer_shell == null) {
        log.err("missing required wayland globals", .{});
        return error.MissingGlobals;
    }

    var font_atlas = try FontAtlas.init(allocator, &cfg);
    defer font_atlas.deinit();

    var shm_pool = try ShmPool.init(allocator, 1920, cfg.bar.height);
    defer shm_pool.deinit();

    var bar = try BarSurface.init(
        globals.compositor.?,
        globals.layer_shell.?,
        globals.shm.?,
        &cfg,
    );
    defer bar.deinit();

    var renderer = try Renderer.init(allocator, &font_atlas, &shm_pool);
    defer renderer.deinit();

    var event_loop = try EventLoop.init(allocator);
    defer event_loop.deinit();

    var inotify = try InotifyWatcher.init(allocator);
    defer inotify.deinit();

    var app = App{
        .allocator = allocator,
        .cfg = cfg,
        .event_loop = event_loop,
        .inotify = inotify,
        .wayland_display = display,
        .wayland_fd = c.wl_display_get_fd(display),
        .bar = bar,
        .shm_pool = shm_pool,
        .renderer = renderer,
        .font_atlas = font_atlas,
        .clock = ClockWidget.init(&cfg),
        .battery = try BatteryWidget.init(allocator, &cfg),
        .volume = try VolumeWidget.init(allocator, &cfg),
        .network = try NetworkWidget.init(allocator, &cfg),
        .workspaces = WorkspacesWidget.init(&cfg),
        .notifications = NotificationsWidget.init(allocator, &cfg),
        .launcher = LauncherWidget.init(allocator, &cfg, globals.compositor.?, globals.xdg_wm_base.?),
        .wallpaper = try WallpaperWidget.init(allocator, globals.compositor.?, globals.shm.?, &cfg),
        .niri = try NiriIpc.init(allocator),
        .pulse = null,
        .dbus = null,
        .idle = null,
        .needs_redraw = true,
        .battery_path = undefined,
        .network_path = undefined,
    };
    g_app = &app;
    defer {
        app.idle.deinit();
        app.pulse.deinit();
        app.dbus.deinit();
        app.niri.deinit();
        app.wallpaper.deinit();
        app.launcher.deinit();
        app.notifications.deinit();
        app.font_atlas.deinit();
        app.shm_pool.deinit();
        app.inotify.deinit();
        app.event_loop.deinit();
    }

    const wayland_fd = c.wl_display_get_fd(display);
    try app.event_loop.add(wayland_fd, linux.EPOLLIN, onWaylandEvent, &app);

    const battery_path = try std.fmt.allocPrintZ(allocator, "/sys/class/power_supply/{s}/capacity", .{cfg.widgets.right[0]});
    defer allocator.free(battery_path);
    @memcpy(app.battery_path[0..battery_path.len], battery_path);
    app.battery_path[battery_path.len] = 0;

    try app.inotify.watch(battery_path, onBatteryChanged, &app);

    if (cfg.widgets.right.len > 2) {
        const network_path = try std.fmt.allocPrintZ(allocator, "/sys/class/net/{s}/operstate", .{"wlan0"});
        defer allocator.free(network_path);
        @memcpy(app.network_path[0..network_path.len], network_path);
        app.network_path[network_path.len] = 0;

        try app.inotify.watch(network_path, onNetworkChanged, &app);
    }

    try app.event_loop.add(app.inotify.inotify_fd, linux.EPOLLIN, onInotifyEvent, &app);

    app.pulse = PulseAudioClient.init(allocator, onVolumeChanged, &app) catch |err| {
        log.warn("failed to init pulseaudio: {}", .{err});
        null;
    };
    if (app.pulse) |*pulse| {
        try app.event_loop.add(pulse.fd.?, linux.EPOLLIN, onPulseEvent, &app);
    }

    app.dbus = DbusClient.init(allocator, onNetworkDbusEvent, &app) catch |err| {
        log.warn("failed to init dbus: {}", .{err});
        null;
    };
    if (app.dbus) |*dbus| {
        try app.event_loop.add(dbus.fd.?, linux.EPOLLIN, onDbusEvent, &app);
    }

    if (app.niri.fd) |fd| {
        try app.event_loop.add(fd, linux.EPOLLIN, onNiriEvent, &app);
    }

    if (globals.seat) |seat| {
        app.idle = IdleManager.init(
            null,
            onIdleStateChange,
            &app,
        );
        if (app.idle) |*idle| {
            idle.requestIdleNotification(seat, 300000);
        }
    }

    while (true) {
        app.needs_redraw = false;
        try app.event_loop.dispatch();

        if (app.needs_redraw) {
            renderBar(&app);
        }
    }
}

fn renderBar(app: *App) void {
    app.renderer.clear(app.cfg.bar.background);

    var x: i32 = @intCast(app.cfg.bar.padding);

    x = app.clock.render(&app.renderer, x, @intCast(app.cfg.bar.padding));
    x += 16;

    x = app.battery.render(&app.renderer, x, @intCast(app.cfg.bar.padding));
    x += 16;

    x = app.volume.render(&app.renderer, x, @intCast(app.cfg.bar.padding));
    x += 16;

    x = app.network.render(&app.renderer, x, @intCast(app.cfg.bar.padding));
    x += 16;

    _ = app.workspaces.render(&app.renderer, x, @intCast(app.cfg.bar.padding));

    app.bar.attachAndCommit();
}

fn onWaylandEvent(fd: i32, mask: u32, context: ?*anyopaque) void {
    _ = fd;
    _ = mask;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    _ = c.wl_display_dispatch(app.wayland_display);
}

fn onInotifyEvent(fd: i32, mask: u32, context: ?*anyopaque) void {
    _ = fd;
    _ = mask;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    app.inotify.handleEvents();
}

fn onBatteryChanged(path: []const u8, context: ?*anyopaque) void {
    _ = path;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    app.needs_redraw = true;
    app.battery.dirty = true;
}

fn onNetworkChanged(path: []const u8, context: ?*anyopaque) void {
    _ = path;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    app.needs_redraw = true;
    app.network.dirty = true;
}

fn onVolumeChanged(volume: u8, muted: bool, context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    app.volume.setVolume(volume, muted);
    app.needs_redraw = true;
}

fn onPulseEvent(fd: i32, mask: u32, context: ?*anyopaque) void {
    _ = fd;
    _ = mask;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (app.pulse) |*pulse| {
        pulse.handleEvent();
        const vol = pulse.getVolume();
        app.volume.setVolume(vol.volume, vol.muted);
        app.needs_redraw = true;
    }
}

fn onNetworkDbusEvent(signal: DbusClient.DbusSignal, context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    switch (signal) {
        .network_up => app.network.setConnected(true),
        .network_down => app.network.setConnected(false),
        .network_changed => app.network.dirty = true,
    }
    app.needs_redraw = true;
}

fn onDbusEvent(fd: i32, mask: u32, context: ?*anyopaque) void {
    _ = fd;
    _ = mask;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (app.dbus) |*dbus| {
        dbus.handleEvent();
    }
}

fn onNiriEvent(fd: i32, mask: u32, context: ?*anyopaque) void {
    _ = fd;
    _ = mask;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    _ = app.niri.request("Workspaces");
    app.workspaces.updateFromIpc(&app.niri);
    app.needs_redraw = true;
}

fn onIdleStateChange(state: IdleManager.IdleState, context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    switch (state) {
        .idle => {
            app.needs_redraw = true;
        },
        .active => {
            app.needs_redraw = true;
        },
    }
}

const Globals = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    seat: ?*c.wl_seat = null,
    output: ?*c.wl_output = null,
    xdg_wm_base: ?*c.xdg_wm_base = null,
};

const registry_listener = c.wl_registry_listener{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

fn onGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void {
    _ = version;
    const globals: *Globals = @ptrCast(@alignCast(data orelse return));
    const iface = std.mem.sliceTo(interface, 0);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        globals.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        globals.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
        globals.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        globals.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 4));
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        globals.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 2));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        globals.xdg_wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1));
    }
}

fn onGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}
