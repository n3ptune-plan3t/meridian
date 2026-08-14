const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "meridian",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const wayland_scan = b.findProgram("wayland-scanner", &.{}).blk: {
        break :blk b.findProgram("wayland-scanner", &.{"/usr/bin", "/usr/local/bin"});
    };

    if (wayland_scan) |scan| {
        const protocols = [_]struct { name: []const u8, xml: []const u8 }{
            .{ .name = "wlr-layer-shell-unstable-v1", .xml = "wlr-layer-shell-unstable-v1" },
            .{ .name = "xdg-shell", .xml = "xdg-shell" },
            .{ .name = "ext-idle-notification-v1", .xml = "ext-idle-notification-v1" },
        };

        const output_dir = b.path("src/generated");
        std.fs.cwd().makeDir(output_dir.getPath()) catch {};

        for (protocols) |proto| {
            const client_header = b.fmt("src/generated/{s}-client-protocol.h", .{proto.name});
            const c_source = b.fmt("src/generated/{s}-client-protocol.c", .{proto.name});

            const xml_path = b.fmt("/usr/share/wayland-protocols/{s}.xml", .{proto.xml});

            _ = b.addSystemCommand(&.{
                scan,
                "client-header",
                xml_path,
                b.path(client_header).getPath(),
            });

            _ = b.addSystemCommand(&.{
                scan,
                "private-code",
                xml_path,
                b.path(c_source).getPath(),
            });

            exe.root_module.addCSourceFile(.{
                .file = b.path(c_source),
                .flags = &.{"-std=c11"},
            });
        }

        exe.addIncludePath(b.path("src/generated"));
    } else {
        std.log.warn("wayland-scanner not found, protocol headers must be pre-generated", .{});
    }

    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-protocols");
    exe.linkSystemLibrary("freetype2");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Meridian");
    run_step.dependOn(&run_cmd.step);
}
