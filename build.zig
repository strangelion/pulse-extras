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
    text: *std.Build.Module,
    vcs_capabilities: *std.Build.Module,
    vcs_identity: *std.Build.Module,
    vcs_risk: *std.Build.Module,
    vcs_detect: *std.Build.Module,
    vcs_provider: *std.Build.Module,
    vcs_cli: *std.Build.Module,
    vcs_snapshot: *std.Build.Module,
    vcs_git: *std.Build.Module,
    vcs_jj: *std.Build.Module,
    vcs_svn: *std.Build.Module,
    all: [36]std.Build.Module.Import = undefined,

    fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vcs_test_config: *std.Build.Module) Modules {
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
                .{ .name = "pulse_host", .module = host },
            },
        });
        const text_mod = b.createModule(.{
            .root_source_file = b.path("shared/pulse/text.zig"),
            .target = target,
            .optimize = optimize,
        });
        const context_mod = b.createModule(.{
            .root_source_file = b.path("shared/pulse/context.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
                .{ .name = "pulse_host", .module = host },
                .{ .name = "pulse_text", .module = text_mod },
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
        const async_host = b.createModule(.{
            .root_source_file = b.path("shared/pulse/async_host.zig"),
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
        const runtime_budget = b.createModule(.{
            .root_source_file = b.path("shared/runtime/budget.zig"),
            .target = target,
            .optimize = optimize,
        });
        const runtime_allocator = b.createModule(.{
            .root_source_file = b.path("shared/runtime/allocator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime_budget", .module = runtime_budget }},
        });
        const runtime_group = b.createModule(.{
            .root_source_file = b.path("shared/runtime/group.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime_allocator", .module = runtime_allocator }},
        });
        const runtime_fifo_task = b.createModule(.{
            .root_source_file = b.path("shared/runtime/fifo_task.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime_group", .module = runtime_group }},
        });
        const runtime_event_log = b.createModule(.{
            .root_source_file = b.path("shared/runtime/event_log.zig"),
            .target = target,
            .optimize = optimize,
        });
        const runtime_temp_store = b.createModule(.{
            .root_source_file = b.path("shared/runtime/temp_store.zig"),
            .target = target,
            .optimize = optimize,
        });
        const process_windows_tree = b.createModule(.{
            .root_source_file = b.path("shared/process/windows_tree.zig"),
            .target = target,
            .optimize = optimize,
        });
        const process_trust = b.createModule(.{
            .root_source_file = b.path("shared/process/trust.zig"),
            .target = target,
            .optimize = optimize,
        });
        const runtime_latest_task = b.createModule(.{
            .root_source_file = b.path("shared/runtime/latest_task.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime_group", .module = runtime_group }},
        });
        const process_mod = b.createModule(.{
            .root_source_file = b.path("shared/process/run.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime_budget", .module = runtime_budget },
                .{ .name = "runtime_allocator", .module = runtime_allocator },
                .{ .name = "process_windows_tree", .module = process_windows_tree },
                .{ .name = "process_trust", .module = process_trust },
                .{ .name = "runtime_event_log", .module = runtime_event_log },
            },
        });
        const vcs_capabilities = b.createModule(.{
            .root_source_file = b.path("shared/vcs/capabilities.zig"),
            .target = target,
            .optimize = optimize,
        });
        const vcs_identity = b.createModule(.{
            .root_source_file = b.path("shared/vcs/identity.zig"),
            .target = target,
            .optimize = optimize,
        });
        const vcs_risk = b.createModule(.{
            .root_source_file = b.path("shared/vcs/risk.zig"),
            .target = target,
            .optimize = optimize,
        });
        const vcs_detect = b.createModule(.{
            .root_source_file = b.path("shared/vcs/detect.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vcs_identity", .module = vcs_identity }},
        });
        const vcs_provider = b.createModule(.{
            .root_source_file = b.path("shared/vcs/provider.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_detect", .module = vcs_detect },
            },
        });
        const vcs_cli = b.createModule(.{
            .root_source_file = b.path("shared/vcs/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "pulse_process", .module = process_mod },
                .{ .name = "vcs_test_config", .module = vcs_test_config },
            },
        });
        const vcs_snapshot = b.createModule(.{
            .root_source_file = b.path("shared/vcs/snapshot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vcs_identity", .module = vcs_identity }},
        });
        const vcs_session = b.createModule(.{
            .root_source_file = b.path("shared/vcs/session.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime_latest_task", .module = runtime_latest_task },
                .{ .name = "runtime_group", .module = runtime_group },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_snapshot", .module = vcs_snapshot },
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_detect", .module = vcs_detect },
            },
        });
        const vcs_panel = b.createModule(.{
            .root_source_file = b.path("shared/vcs/panel.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_session", .module = vcs_session },
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_detect", .module = vcs_detect },
                .{ .name = "pulse_abi", .module = abi },
                .{ .name = "pulse_ui_model", .module = ui_model },
            },
        });
        const vcs_host_query = b.createModule(.{
            .root_source_file = b.path("shared/vcs/host_query.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_abi", .module = abi },
                .{ .name = "pulse_host", .module = host },
                .{ .name = "pulse_context", .module = context_mod },
                .{ .name = "pulse_async_host", .module = async_host },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_panel", .module = vcs_panel },
                .{ .name = "pulse_ui_model", .module = ui_model },
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_detect", .module = vcs_detect },
            },
        });
        const vcs_git = b.createModule(.{
            .root_source_file = b.path("shared/vcs/providers/git.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_cli", .module = vcs_cli },
                .{ .name = "vcs_detect", .module = vcs_detect },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_session", .module = vcs_session },
                .{ .name = "vcs_panel", .module = vcs_panel },
                .{ .name = "pulse_ui_model", .module = ui_model },
                .{ .name = "pulse_process", .module = process_mod },
                .{ .name = "vcs_test_config", .module = vcs_test_config },
            },
        });
        const vcs_jj = b.createModule(.{
            .root_source_file = b.path("shared/vcs/providers/jj.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_cli", .module = vcs_cli },
                .{ .name = "vcs_detect", .module = vcs_detect },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_session", .module = vcs_session },
                .{ .name = "pulse_process", .module = process_mod },
                .{ .name = "vcs_test_config", .module = vcs_test_config },
            },
        });
        const vcs_svn = b.createModule(.{
            .root_source_file = b.path("shared/vcs/providers/svn.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_capabilities", .module = vcs_capabilities },
                .{ .name = "vcs_cli", .module = vcs_cli },
                .{ .name = "vcs_detect", .module = vcs_detect },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_session", .module = vcs_session },
                .{ .name = "pulse_process", .module = process_mod },
                .{ .name = "vcs_test_config", .module = vcs_test_config },
            },
        });
        const vcs_approval = b.createModule(.{
            .root_source_file = b.path("shared/vcs/approval.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_detect", .module = vcs_detect },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_cli", .module = vcs_cli },
                .{ .name = "vcs_git", .module = vcs_git },
                .{ .name = "vcs_host_query", .module = vcs_host_query },
                .{ .name = "pulse_process", .module = process_mod },
                .{ .name = "process_trust", .module = process_trust },
                .{ .name = "vcs_test_config", .module = vcs_test_config },
                .{ .name = "pulse_async_host", .module = async_host },
                .{ .name = "pulse_abi", .module = abi },
            },
        });
        const vcs_windows_evidence = b.createModule(.{
            .root_source_file = b.path("shared/vcs/windows_evidence.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_approval", .module = vcs_approval },
                .{ .name = "vcs_provider", .module = vcs_provider },
            },
        });
        var modules = Modules{ .raw = raw, .abi = abi, .host = host, .commands = commands, .context = context_mod, .ui_model = ui_model, .ui_mount = ui_mount, .diagnostics = diagnostics, .process = process_mod, .text = text_mod, .vcs_capabilities = vcs_capabilities, .vcs_identity = vcs_identity, .vcs_risk = vcs_risk, .vcs_detect = vcs_detect, .vcs_provider = vcs_provider, .vcs_cli = vcs_cli, .vcs_snapshot = vcs_snapshot, .vcs_git = vcs_git, .vcs_jj = vcs_jj, .vcs_svn = vcs_svn };
        modules.all = .{
            .{ .name = "pulse_raw", .module = raw },
            .{ .name = "pulse_abi", .module = abi },
            .{ .name = "pulse_host", .module = host },
            .{ .name = "pulse_commands", .module = commands },
            .{ .name = "pulse_context", .module = context_mod },
            .{ .name = "pulse_ui_model", .module = ui_model },
            .{ .name = "pulse_async_host", .module = async_host },
            .{ .name = "pulse_ui_mount", .module = ui_mount },
            .{ .name = "pulse_diagnostics", .module = diagnostics },
            .{ .name = "runtime_budget", .module = runtime_budget },
            .{ .name = "runtime_allocator", .module = runtime_allocator },
            .{ .name = "runtime_latest_task", .module = runtime_latest_task },
            .{ .name = "runtime_group", .module = runtime_group },
            .{ .name = "runtime_fifo_task", .module = runtime_fifo_task },
            .{ .name = "runtime_event_log", .module = runtime_event_log },
            .{ .name = "runtime_temp_store", .module = runtime_temp_store },
            .{ .name = "process_windows_tree", .module = process_windows_tree },
            .{ .name = "process_trust", .module = process_trust },
            .{ .name = "pulse_process", .module = process_mod },
            .{ .name = "pulse_text", .module = text_mod },
            .{ .name = "vcs_capabilities", .module = vcs_capabilities },
            .{ .name = "vcs_identity", .module = vcs_identity },
            .{ .name = "vcs_risk", .module = vcs_risk },
            .{ .name = "vcs_detect", .module = vcs_detect },
            .{ .name = "vcs_provider", .module = vcs_provider },
            .{ .name = "vcs_cli", .module = vcs_cli },
            .{ .name = "vcs_snapshot", .module = vcs_snapshot },
            .{ .name = "vcs_session", .module = vcs_session },
            .{ .name = "vcs_panel", .module = vcs_panel },
            .{ .name = "vcs_host_query", .module = vcs_host_query },
            .{ .name = "vcs_git", .module = vcs_git },
            .{ .name = "vcs_approval", .module = vcs_approval },
            .{ .name = "vcs_windows_evidence", .module = vcs_windows_evidence },
            .{ .name = "vcs_jj", .module = vcs_jj },
            .{ .name = "vcs_svn", .module = vcs_svn },
            .{ .name = "vcs_test_config", .module = vcs_test_config },
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

    const vcs_test_options = b.addOptions();
    const environ = &b.graph.environ_map;
    vcs_test_options.addOption([]const u8, "path", environ.get("PATH") orelse "");
    vcs_test_options.addOption([]const u8, "system_root", environ.get("SystemRoot") orelse environ.get("SYSTEMROOT") orelse "");
    vcs_test_options.addOption(bool, "require_git", std.mem.eql(u8, environ.get("PULSE_REQUIRE_GIT") orelse "", "1"));
    vcs_test_options.addOption(bool, "require_jj", std.mem.eql(u8, environ.get("PULSE_REQUIRE_JJ") orelse "", "1"));
    vcs_test_options.addOption(bool, "require_svn", std.mem.eql(u8, environ.get("PULSE_REQUIRE_SVN") orelse "", "1"));
    vcs_test_options.addOption([]const u8, "svn_working_copy", environ.get("PULSE_TEST_SVN_WC") orelse "");
    const vcs_test_config = vcs_test_options.createModule();

    var dll_modules = Modules.add(b, target, optimize, vcs_test_config);
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

    // Optional trusted provisioning implementation compiled into the DLL.
    // The default is always locked. Never load an arbitrary runtime source.
    const source_path = b.option([]const u8, "vcs-approval-source", "Trusted reviewed approval provisioning Zig source (relative to repository)") orelse "extensions/vcs-panel/locked_source.zig";
    const native_source = b.createModule(.{
        .root_source_file = b.path(source_path),
        .target = target,
        .optimize = optimize,
        .imports = dll_modules.imports(),
    });
    const vcs_panel_dll = b.addLibrary(.{
        .name = "pulse_vcs_panel",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/vcs-panel/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = dll_modules.imports(),
        }),
    });
    vcs_panel_dll.root_module.addImport("vcs_native_source", native_source);
    b.installArtifact(vcs_panel_dll);

    // Every module also runs its own tests on the host target, so the wrappers
    // are checked even when the probe does not use them yet.
    var host_modules = Modules.add(b, b.graph.host, .Debug, vcs_test_config);
    const locked_source = b.createModule(.{
        .root_source_file = b.path("extensions/vcs-panel/locked_source.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = host_modules.imports(),
    });
    const test_sources = [_][]const u8{
        "extensions/abi-probe/main.zig",
        "extensions/hello-panel/main.zig",
        "extensions/vcs-panel/main.zig",
        "shared/diagnostics/probe_log.zig",
        "shared/process/run.zig",
        "shared/runtime/budget.zig",
        "shared/runtime/allocator.zig",
        "shared/runtime/latest_task.zig",
        "shared/runtime/group.zig",
        "shared/runtime/fifo_task.zig",
        "shared/runtime/event_log.zig",
        "shared/runtime/temp_store.zig",
        "shared/process/windows_tree.zig",
        "shared/process/trust.zig",
        "shared/pulse/abi.zig",
        "shared/pulse/text.zig",
        "shared/pulse/host.zig",
        "shared/pulse/commands.zig",
        "shared/pulse/context.zig",
        "shared/pulse/ui_model.zig",
        "shared/pulse/async_host.zig",
        "shared/pulse/ui_mount.zig",
        "shared/vcs/capabilities.zig",
        "shared/vcs/identity.zig",
        "shared/vcs/risk.zig",
        "shared/vcs/detect.zig",
        "shared/vcs/provider.zig",
        "shared/vcs/cli.zig",
        "shared/vcs/snapshot.zig",
        "shared/vcs/session.zig",
        "shared/vcs/panel.zig",
        "shared/vcs/host_query.zig",
        "shared/vcs/approval.zig",
        "shared/vcs/windows_evidence.zig",
        "shared/vcs/providers/git.zig",
        "shared/vcs/providers/jj.zig",
        "shared/vcs/providers/svn.zig",
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
        if (std.mem.eql(u8, source, "extensions/vcs-panel/main.zig")) unit_tests.root_module.addImport("vcs_native_source", locked_source);
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
