const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});
    const wayland_protocols_dep = b.dependency("wayland-protocols", .{});
    const wlr_protocols_dep = b.dependency("wlr-protocols", .{});

    const protocol_step = b.step("protocols", "Generate wayland protocol binding code using ./scanner.py");

    const protocols = b.addSystemCommand(&.{
        "/usr/bin/env",
        "python3",
    });
    protocols.addFileArg(b.path("scanner.py"));
    const protocol_dir = protocols.addOutputDirectoryArg("protocols/");
    protocols.addDirectoryArg(wayland_dep.path("protocol"));
    protocols.addDirectoryArg(wayland_protocols_dep.path("."));
    protocols.addDirectoryArg(wlr_protocols_dep.path("."));

    protocol_step.dependOn(&protocols.step);

    const protocol_module = b.addModule("protocols", .{
        .root_source_file = protocol_dir.path(b, "proto.zig"),
        .target = target,
        .optimize = optimize,
    });

    const type2_module = b.addModule("type2", .{
        .root_source_file = b.path("src/type2.zig"),
    });

    const way2_module = b.addModule("way2", .{
        .root_source_file = b.path("src/way2.zig"),
        .imports = &.{
            .{ .name = "type2", .module = type2_module },
            .{ .name = "protocols", .module = protocol_module },
        },
    });

    const draw2_module = b.addModule("draw2", .{
        .root_source_file = b.path("src/draw2.zig"),
        .imports = &.{.{ .name = "type2", .module = type2_module }},
    });

    const red_example = b.addExecutable(.{
        .name = "way2_example_red",
        .root_source_file = b.path("examples/red.zig"),
        .target = target,
        .optimize = optimize,
    });
    red_example.root_module.addImport("way2", way2_module);
    red_example.root_module.addImport("draw2", draw2_module);

    b.installArtifact(red_example);

    const run_cmd = b.addRunArtifact(red_example);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the red example");
    run_step.dependOn(&run_cmd.step);
}
