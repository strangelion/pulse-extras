const std = @import("std");

const Modules = struct {
    raw: *std.Build.Module,
    abi: *std.Build.Module,
    host: *std.Build.Module,
    commands: *std.Build.Module,
    context: *std.Build.Module,
    ui_model: *std.Build.Module,
    ui_mount: *std.Build.Module,
    diagnostics: *std.Build.Module,
    process: *std.Build.Module,
    all: [9]std.Build.Module.Import = undefined,

    fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
        const raw = b.createModule(.{
            .root_source_file = b.path("shared/pulse/raw/pulse_all.zig"),
            .target = target,
            .optimize = optimize,
        });
        const abi = b.createModule(.{
            .root_source_file = b.path("shared/pulse/abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pulse_raw", .module = raw }},
        });
        const host = b.createModule(.{
            .root_source_file = b.path("shared/pulse/host.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
            },
        });
        const commands = b.createModule(.{
            .root_source_file = b.path("shared/pulse/commands.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
            },
        });
        const context_mod = b.createModule(.{
            .root_source_file = b.path("shared/pulse/context.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
                .{ .name = "pulse_host", .module = host },
            },
        });
        const ui_model = b.createModule(.{
            .root_source_file = b.path("shared/pulse/ui_model.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
                .{ .name = "pulse_host", .module = host },
            },
        });
        const ui_mount = b.createModule(.{
            .root_source_file = b.path("shared/pulse/ui_mount.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
                .{ .name = "pulse_host", .module = host },
            },
        });
        const diagnostics = b.createModule(.{
            .root_source_file = b.path("shared/diagnostics/probe_log.zig"),
            .target = target,
            .optimize = optimize,
        });
        const process_mod = b.createModule(.{
            .root_source_file = b.path("shared/process/run.zig"),
            .target = target,
            .optimize = optimize,
        });
        var modules = Modules{ .raw = raw, .abi = abi, .host = host, .commands = commands, .context = context_mod, .ui_model = ui_model, .ui_mount = ui_mount, .diagnostics = diagnostics, .process = process_mod };
        modules.all = .{
            .{ .name = "pulse_raw", .module = raw },
            .{ .name = "pulse_abi", .module = abi },
            .{ .name = "pulse_host", .module = host },
            .{ .name = "pulse_commands", .module = commands },
            .{ .name = "pulse_context", .module = context_mod },
            .{ .name = "pulse_ui_model", .module = ui_model },
            .{ .name = "pulse_ui_mount", .module = ui_mount },
            .{ .name = "pulse_diagnostics", .module = diagnostics },
            .{ .name = "pulse_process", .module = process_mod },
        };
        return modules;
    }

    fn imports(self: *const Modules) []const std.Build.Module.Import {
        return &self.all;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .msvc,
    } });
    const optimize = b.standardOptimizeOption(.{});

    var dll_modules = Modules.add(b, target, optimize);
    const dll = b.addLibrary(.{
        .name = "pulse_abi_probe",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/abi-probe/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = dll_modules.imports(),
        }),
    });
    b.installArtifact(dll);

    const hello_panel = b.addLibrary(.{
        .name = "pulse_hello_panel",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/hello-panel/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = dll_modules.imports(),
        }),
    });
    b.installArtifact(hello_panel);

    // Every module also runs its own tests on the host target, so the wrappers
    // are checked even when the probe does not use them yet.
    var host_modules = Modules.add(b, b.graph.host, .Debug);
    const test_sources = [_][]const u8{
        "extensions/abi-probe/main.zig",
        "extensions/hello-panel/main.zig",
        "shared/diagnostics/probe_log.zig",
        "shared/process/run.zig",
        "shared/pulse/host.zig",
        "shared/pulse/commands.zig",
        "shared/pulse/context.zig",
        "shared/pulse/ui_model.zig",
        "shared/pulse/ui_mount.zig",
    };
    const test_step = b.step("test", "Run native ABI, wrapper and lifecycle regression tests");
    for (test_sources) |source| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = host_modules.imports(),
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
