const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .msvc,
    } });
    const optimize = b.standardOptimizeOption(.{});
    const abi = b.createModule(.{
        .root_source_file = b.path("shared/pulse/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dll = b.addLibrary(.{
        .name = "pulse_abi_probe",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/abi-probe/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pulse_abi", .module = abi }},
        }),
    });
    b.installArtifact(dll);

    const native_abi = b.createModule(.{
        .root_source_file = b.path("shared/pulse/abi.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/abi-probe/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "pulse_abi", .module = native_abi }},
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run native ABI and lifecycle regression tests").dependOn(&run_tests.step);
}
