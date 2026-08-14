# Meridian

A lightweight Wayland shell for niri, written in Zig.

## Features

- **Zero GPU usage** — CPU-only rendering via `wl_shm`
- **Minimal resource usage** — epoll-based event loop, no busy-polling
- **Battery optimized** — Page-aligned buffers, damage tracking, triple buffering
- **Event-driven** — inotify, PulseAudio, D-Bus, Niri IPC (no polling)
- **Configurable** — TOML config file
- **Widgets** — Clock, Battery, Volume, Network, Workspaces, Notifications, Launcher, Wallpaper

## Requirements

- Zig 0.16.0
- Wayland compositor with `wlr-layer-shell` support (niri, Hyprland, Sway)
- System libraries:
  - `libwayland-dev`
  - `wayland-protocols`
  - `libfreetype-dev`
  - `pkg-config`

## Building

```bash
# Debug
zig build

# Release
zig build -Doptimize=ReleaseFast

# Minimal size
zig build -Doptimize=ReleaseSmall
```

## Running

```bash
./zig-out/bin/meridian
```

## Configuration

Copy `config/meridian.toml` to `~/.config/meridian/config.toml` and edit:

```toml
[bar]
position = "top"
height = 32
background = "#1A1B26"
foreground = "#C0CAF5"

[widgets]
left = ["workspaces"]
center = ["clock"]
right = ["battery", "volume", "network"]
```

## Architecture

```
epoll_wait (blocks, CPU sleeps)
    ↓
battery file changes → inotify → render
PulseAudio event → PA socket → render
Niri workspace change → niri socket → render
NetworkManager state → D-Bus socket → render
    ↓
CPU rasterize → wl_shm commit → compositor displays
```

## License

MIT
