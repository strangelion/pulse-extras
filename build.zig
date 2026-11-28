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
    vcs_hg: *std.Build.Module,
    all: [44]std.Build.Module.Import = undefined,

    fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vcs_test_config: *std.Build.Module, companion_config: *std.Build.Module) Modules {
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
        const task_progress = b.createModule(.{
            .root_source_file = b.path("shared/pulse/task_progress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
            },
        });
        const pickers = b.createModule(.{
            .root_source_file = b.path("shared/pulse/pickers_compat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pulse_abi", .module = abi }},
        });
        const dialogs_v2 = b.createModule(.{
            .root_source_file = b.path("shared/pulse/dialogs_v2_compat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_raw", .module = raw },
                .{ .name = "pulse_abi", .module = abi },
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
        const runtime_retention = b.createModule(.{
            .root_source_file = b.path("shared/runtime/retention.zig"),
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
        const vcs_hg = b.createModule(.{
            .root_source_file = b.path("shared/vcs/providers/hg.zig"),
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
        const vcs_git_index_transaction = b.createModule(.{
            .root_source_file = b.path("shared/vcs/git_index_transaction.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pulse_process", .module = process_mod },
                .{ .name = "vcs_provider", .module = vcs_provider },
                .{ .name = "vcs_approval", .module = vcs_approval },
                .{ .name = "vcs_identity", .module = vcs_identity },
                .{ .name = "vcs_windows_evidence", .module = vcs_windows_evidence },
                .{ .name = "process_trust", .module = process_trust },
                .{ .name = "vcs_cli", .module = vcs_cli },
            },
        });
        const companion_library = b.createModule(.{
            .root_source_file = b.path("shared/companion_extension.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime_retention", .module = runtime_retention },
                .{ .name = "runtime_budget", .module = runtime_budget },
                .{ .name = "runtime_group", .module = runtime_group },
                .{ .name = "runtime_temp_store", .module = runtime_temp_store },
                .{ .name = "process_trust", .module = process_trust },
                .{ .name = "pulse_process", .module = process_mod },
            },
        });
        var modules = Modules{ .raw = raw, .abi = abi, .host = host, .commands = commands, .context = context_mod, .ui_model = ui_model, .ui_mount = ui_mount, .diagnostics = diagnostics, .process = process_mod, .text = text_mod, .vcs_capabilities = vcs_capabilities, .vcs_identity = vcs_identity, .vcs_risk = vcs_risk, .vcs_detect = vcs_detect, .vcs_provider = vcs_provider, .vcs_cli = vcs_cli, .vcs_snapshot = vcs_snapshot, .vcs_git = vcs_git, .vcs_jj = vcs_jj, .vcs_svn = vcs_svn, .vcs_hg = vcs_hg };
        modules.all = .{
            .{ .name = "companion_library", .module = companion_library },
            .{ .name = "companion_config", .module = companion_config },
            .{ .name = "pulse_raw", .module = raw },
            .{ .name = "pulse_abi", .module = abi },
            .{ .name = "pulse_host", .module = host },
            .{ .name = "pulse_commands", .module = commands },
            .{ .name = "pulse_context", .module = context_mod },
            .{ .name = "pulse_task_progress", .module = task_progress },
            .{ .name = "pulse_async_host", .module = async_host },
            .{ .name = "pulse_pickers", .module = pickers },
            .{ .name = "pulse_dialogs_v2", .module = dialogs_v2 },
            .{ .name = "pulse_ui_model", .module = ui_model },
            .{ .name = "pulse_ui_mount", .module = ui_mount },
            .{ .name = "pulse_diagnostics", .module = diagnostics },
            .{ .name = "runtime_retention", .module = runtime_retention },
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
            .{ .name = "vcs_git_index_transaction", .module = vcs_git_index_transaction },
            .{ .name = "vcs_jj", .module = vcs_jj },
            .{ .name = "vcs_svn", .module = vcs_svn },
            .{ .name = "vcs_hg", .module = vcs_hg },
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
    vcs_test_options.addOption(bool, "require_hg", std.mem.eql(u8, environ.get("PULSE_REQUIRE_HG") orelse "", "1"));
    vcs_test_options.addOption([]const u8, "hg_working_copy", environ.get("PULSE_TEST_HG_WC") orelse "");
    const vcs_test_config = vcs_test_options.createModule();

    const companion_options = b.addOptions();
    const runtime_digest = b.option([]const u8, "companion-runtime-sha256", "Approved runtime DLL digest for bundled Companion") orelse "";
    const helper_digest = b.option([]const u8, "companion-helper-sha256", "Approved bundled helper digest") orelse "";
    for ([_][]const u8{ runtime_digest, helper_digest }) |digest| {
        if (digest.len == 0) continue;
        if (digest.len != 64 or !isHexDigest(digest)) {
            @panic("companion digest options must be exactly 64 hex characters; a trailing CR from a CRLF file silently disables the pin");
        }
    }
    companion_options.addOption([]const u8, "runtime_sha256", runtime_digest);
    companion_options.addOption([]const u8, "helper_sha256", helper_digest);
    const companion_config = companion_options.createModule();

    var dll_modules = Modules.add(b, target, optimize, vcs_test_config, companion_config);
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
    b.installArtifact(hello_panel);

    const share_options = b.addOptions();
    const share_lan_digest = b.option([]const u8, "share-lan-sha256", "Approved bundled Share LAN executable digest") orelse "";
    const share_local_digest = b.option([]const u8, "share-local-sha256", "Approved bundled Share local supervisor digest") orelse "";
    const share_worker_digest = b.option([]const u8, "share-worker-sha256", "Approved bundled Share worker digest") orelse "";
    const share_pake_digest = b.option([]const u8, "share-pake-sha256", "Approved bundled Share CPace executable digest") orelse "";
    for ([_][]const u8{ share_lan_digest, share_local_digest, share_worker_digest, share_pake_digest }) |digest| {
        if (digest.len != 0 and (digest.len != 64 or !isHexDigest(digest))) @panic("Share digest must be exactly 64 hex characters");
    }
    share_options.addOption([]const u8, "lan_sha256", share_lan_digest);
    share_options.addOption([]const u8, "local_sha256", share_local_digest);
    share_options.addOption([]const u8, "worker_sha256", share_worker_digest);
    share_options.addOption([]const u8, "pake_sha256", share_pake_digest);
    const share_config = share_options.createModule();

    const desktop_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const desktop_modules = Modules.add(b, desktop_target, optimize, vcs_test_config, companion_config);
    const desktop_root = b.createModule(.{
        .root_source_file = b.path("extensions/share/desktop.zig"),
        .target = desktop_target,
        .optimize = optimize,
        .imports = desktop_modules.imports(),
        .link_libc = true,
    });
    desktop_root.addImport("share_config", share_config);
    desktop_root.addCSourceFile(.{ .file = b.path("extensions/share/desktop_win32.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    desktop_root.addWin32ResourceFile(.{ .file = b.path("extensions/share/desktop.rc"), .include_paths = &.{b.path("extensions/share")} });
    for ([_][]const u8{ "user32", "gdi32", "comctl32", "shell32", "ole32", "uuid", "iphlpapi", "bcrypt" }) |lib|
        desktop_root.linkSystemLibrary(lib, .{});
    const desktop = b.addExecutable(.{
        .name = "pulse-share-desktop",
        .root_module = desktop_root,
        .win32_manifest = b.path("extensions/share/desktop.manifest"),
    });
    desktop.subsystem = .windows;
    const desktop_digest = b.addSystemCommand(&.{"python"});
    desktop_digest.addFileArg(b.path("extensions/share/desktop_digest.py"));
    desktop_digest.addFileArg(desktop.getEmittedBin());
    const desktop_digest_source = desktop_digest.addOutputFileArg("desktop-digest.zig");

    // Share is experimental and intentionally absent from the default install.
    const share = b.addLibrary(.{
        .name = "pulse_share",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/share/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = dll_modules.imports(),
        }),
    });
    share.root_module.addImport("share_config", share_config);
    share.root_module.addAnonymousImport("share_desktop_digest", .{ .root_source_file = desktop_digest_source });
    const share_dev = b.step("share-dev", "Build the Share desktop application and Pulse adapter");
    share_dev.dependOn(&b.addInstallArtifact(desktop, .{}).step);
    share_dev.dependOn(&b.addInstallArtifact(share, .{}).step);

    // Optional trusted provisioning implementation compiled into the DLL.
    // The default is always locked. Never load an arbitrary runtime source.
    const source_path = b.option([]const u8, "vcs-approval-source", "Trusted reviewed approval provisioning Zig source (relative to repository)") orelse "extensions/vcs-panel/default_source.zig";
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

    // Experimental settings contribution; not a release-ready pet runtime.
    const companion = b.addLibrary(.{
        .name = "pulse_companion",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("extensions/companion/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = dll_modules.imports(),
        }),
    });
    b.installArtifact(companion);

    // Standalone companion uses the existing GNU Windows native ABI.
    // Explicit step: no demo in the default production DLL install.
    const pet_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });

    // Explicit Share worker/harness only. No automatic network listener,
    // normal install or release registration.
    const share_worker_root = b.createModule(.{
        .root_source_file = b.path("shared/share/worker.zig"),
        .target = pet_target,
        .optimize = optimize,
        .link_libc = true,
    });
    share_worker_root.addCSourceFiles(.{
        .files = &.{"shared/share/worker_win32.c"},
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    share_worker_root.linkSystemLibrary("shell32", .{});
    const share_worker = b.addExecutable(.{ .name = "pulse-share-worker", .root_module = share_worker_root });
    const share_local_root = b.createModule(.{
        .target = pet_target,
        .optimize = optimize,
        .link_libc = true,
    });
    share_local_root.addCSourceFiles(.{
        .files = &.{
            "shared/share/local_copy_win32.c",
            "shared/process/image_win32.c",
            "shared/process/job_win32.c",
        },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    for ([_][]const u8{ "shell32", "bcrypt", "advapi32" }) |lib|
        share_local_root.linkSystemLibrary(lib, .{});
    const share_local = b.addExecutable(.{ .name = "pulse-share-local", .root_module = share_local_root });
    const share_local_step = b.step("share-local", "Build the isolated Share worker and local developer harness");
    share_local_step.dependOn(&b.addInstallArtifact(share_worker, .{}).step);
    share_local_step.dependOn(&b.addInstallArtifact(share_local, .{}).step);

    var pet_modules = Modules.add(b, pet_target, optimize, vcs_test_config, companion_config);
    const pet_root = b.createModule(.{
        .root_source_file = b.path("shared/companion/pet_demo.zig"),
        .target = pet_target,
        .optimize = optimize,
        .imports = pet_modules.imports(),
        .link_libc = true,
    });
    pet_root.addCSourceFiles(.{
        .files = &.{
            "shared/companion/pet_demo_win32.c",
            "shared/companion/pet_decode_win32.c",
            "shared/companion/pet_surface_win32.c",
            "shared/companion/pet_config_win32.c",
            "shared/companion/pet_crash_watch_win32.c",
            "shared/companion/pet_private_root_win32.c",
            "shared/fs/private_root_win32.c",
            "shared/diagnostics/crash_win32.c",
            "shared/diagnostics/store_win32.c",
        },
    });
    for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32", "windowscodecs", "uuid", "advapi32" }) |lib|
        pet_root.linkSystemLibrary(lib, .{});
    // Explicit experimental backend. The default WIC build is unchanged.
    const pet_libwebp = b.option(bool, "pet-libwebp", "Use the pinned static WebP decoder for pet-demo") orelse false;
    if (pet_libwebp) {
        const source = b.path(".local/deps/libwebp-1.6.0");
        pet_root.addIncludePath(source);
        pet_root.addCMacro("PULSE_PET_LIBWEBP", "1");
        pet_root.addCSourceFiles(.{
            .root = source,
            .files = &.{
                "src/dec/alpha_dec.c",           "src/dec/buffer_dec.c",               "src/dec/frame_dec.c",
                "src/dec/idec_dec.c",            "src/dec/io_dec.c",                   "src/dec/quant_dec.c",
                "src/dec/tree_dec.c",            "src/dec/vp8_dec.c",                  "src/dec/vp8l_dec.c",
                "src/dec/webp_dec.c",            "src/dsp/alpha_processing.c",         "src/dsp/cpu.c",
                "src/dsp/dec.c",                 "src/dsp/dec_clip_tables.c",          "src/dsp/filters.c",
                "src/dsp/lossless.c",            "src/dsp/rescaler.c",                 "src/dsp/upsampling.c",
                "src/dsp/yuv.c",                 "src/dsp/alpha_processing_sse2.c",    "src/dsp/dec_sse2.c",
                "src/dsp/filters_sse2.c",        "src/dsp/lossless_sse2.c",            "src/dsp/rescaler_sse2.c",
                "src/dsp/upsampling_sse2.c",     "src/dsp/yuv_sse2.c",                 "src/dsp/alpha_processing_sse41.c",
                "src/dsp/dec_sse41.c",           "src/dsp/lossless_sse41.c",           "src/dsp/upsampling_sse41.c",
                "src/dsp/yuv_sse41.c",           "src/dsp/lossless_avx2.c",            "src/utils/bit_reader_utils.c",
                "src/utils/color_cache_utils.c", "src/utils/filters_utils.c",          "src/utils/huffman_utils.c",
                "src/utils/palette.c",           "src/utils/quant_levels_dec_utils.c", "src/utils/rescaler_utils.c",
                "src/utils/random_utils.c",      "src/utils/thread_utils.c",
            },
            .flags = &.{"-DWEBP_DSP_OMIT_C_CODE=0"},
        });
        pet_root.addCSourceFile(.{ .file = b.path("shared/companion/pet_webp_utils.c"), .flags = &.{"-DWEBP_DSP_OMIT_C_CODE=0"} });
    }
    const pet = b.addExecutable(.{ .name = "pulse-pet-demo", .root_module = pet_root });
    if (pet_libwebp) {
        // Verify before the compiler attempts to open any third-party source.
        // Never download implicitly during a build.
        const verify_webp = b.addSystemCommand(&.{"python"});
        verify_webp.addFileArg(b.path("scripts/install_pet_webp.py"));
        verify_webp.addArg("--check");
        pet.step.dependOn(&verify_webp.step);
    }
    const pet_step = b.step("pet-demo", "Build and install the experimental standalone Windows companion");
    pet_step.dependOn(&b.addInstallArtifact(pet, .{}).step);

    // Separate, explicitly invoked crash collector; never installed with the default DLLs.
    const dump_root = b.createModule(.{
        .target = pet_target,
        .optimize = optimize,
        .link_libc = true,
    });
    dump_root.addCSourceFiles(.{
        .files = &.{ "shared/companion/pet_crash_capture_win32.c", "shared/process/job_win32.c", "shared/diagnostics/crash_win32.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    dump_root.linkSystemLibrary("shell32", .{});
    dump_root.linkSystemLibrary("advapi32", .{});
    const dump_capture = b.addExecutable(.{ .name = "pulse-pet-crash-capture", .root_module = dump_root });
    b.step("pet-crash-capture", "Build the opt-in standalone child crash collector").dependOn(&b.addInstallArtifact(dump_capture, .{}).step);

    // Optional GNU supervisor DLL; a versioned C table is the only exported
    // contract. The MSVC settings extension need not link GNU CRT objects.
    const runtime_root = b.createModule(.{
        .target = pet_target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_root.addCSourceFiles(.{
        .files = &.{ "shared/companion/pet_supervisor_win32.c", "shared/companion/pet_runtime_bridge_win32.c", "shared/companion/pet_private_root_win32.c", "shared/companion/pet_catalog_store_win32.c", "shared/companion/pet_market_http_win32.c", "shared/fs/private_root_win32.c", "shared/process/image_win32.c", "shared/process/job_win32.c", "shared/process/metrics_win32.c", "shared/network/https_win32.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    runtime_root.linkSystemLibrary("psapi", .{});
    runtime_root.linkSystemLibrary("advapi32", .{});
    runtime_root.linkSystemLibrary("winhttp", .{});
    const runtime_bridge = b.addLibrary(.{
        .name = "pulse_companion_runtime",
        .linkage = .dynamic,
        .root_module = runtime_root,
    });
    const runtime_step = b.step("companion-runtime-bridge", "Build the experimental versioned native supervisor bridge");
    runtime_step.dependOn(&b.addInstallArtifact(runtime_bridge, .{}).step);

    const bridge_probe = b.addExecutable(.{
        .name = "companion-bridge-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shared/companion_bridge_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = dll_modules.imports(),
        }),
    });
    b.step("companion-bridge-probe", "Build the isolated MSVC runtime integration probe").dependOn(&b.addInstallArtifact(bridge_probe, .{}).step);

    // Every module also runs its own tests on the host target, so the wrappers
    // are checked even when the probe does not use them yet.
    var host_modules = Modules.add(b, b.graph.host, .Debug, vcs_test_config, companion_config);
    const locked_source = b.createModule(.{
        .root_source_file = b.path("extensions/vcs-panel/locked_source.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = host_modules.imports(),
    });
    const import_integration = b.step("test-companion-import", "Run Windows real-helper and durable inventory integration");
    if (b.graph.host.result.os.tag == .windows and b.graph.host.result.cpu.arch == .x86_64) {
        const import_root = b.createModule(.{
            .root_source_file = b.path("shared/companion_import_integration.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
            .imports = host_modules.imports(),
        });
        import_root.addCSourceFiles(.{
            .files = &.{ "shared/companion/pet_catalog_store_win32.c", "tests/companion/pet_catalog_store_fixture.c", "shared/companion/pet_market_http_win32.c", "shared/companion/pet_private_root_win32.c", "shared/fs/private_root_win32.c", "shared/network/https_win32.c" },
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        import_root.linkSystemLibrary("winhttp", .{});
        import_root.linkSystemLibrary("advapi32", .{});
        const import_tests = b.addTest(.{ .root_module = import_root });
        import_integration.dependOn(&b.addRunArtifact(import_tests).step);
    }
    const test_sources = [_][]const u8{
        "extensions/abi-probe/main.zig",
        "extensions/hello-panel/main.zig",
        "extensions/share/main.zig",
        "shared/share/transfer.zig",
        "extensions/vcs-panel/main.zig",
        "extensions/vcs-panel/default_source.zig",
        "extensions/companion/main.zig",
        "shared/diagnostics/probe_log.zig",
        "shared/process/run.zig",
        "shared/runtime/budget.zig",
        "shared/runtime/retention.zig",
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
        "shared/pulse/async_host.zig",
        "shared/pulse/task_progress.zig",
        "shared/pulse/pickers_compat.zig",
        "shared/pulse/dialogs_v2_compat.zig",
        "shared/pulse/ui_model.zig",
        "shared/pulse/ui_mount.zig",
        "shared/vcs/capabilities.zig",
        "shared/vcs/identity.zig",
        "shared/vcs/git_index_transaction.zig",
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
        "shared/vcs/providers/hg.zig",
        "shared/companion_extension.zig",
        "shared/companion/openpets_protocol.zig",
        "shared/companion/openpets_lease.zig",
        "shared/companion/behavior.zig",
        "shared/companion/pet_assets.zig",
        "shared/companion/pet_activities.zig",
        "shared/companion/pet_wardrobe.zig",
        "shared/companion/pet_package.zig",
        "shared/companion/pet_memory.zig",
        "shared/companion/pet_manager.zig",
        "shared/companion/pet_catalog.zig",
        "shared/companion/pet_history.zig",
        "shared/companion/pet_inventory.zig",
        "shared/companion/pet_recovery_scan.zig",
        "shared/companion/pet_removal_receipt.zig",
        "shared/companion/pet_fingerprint.zig",
        "shared/companion/pet_import.zig",
        "shared/companion/pet_import_helper.zig",
        "shared/companion/pet_market.zig",
        "shared/companion/pet_market_cache.zig",
        "shared/companion/pet_market_download.zig",
        "shared/companion/pet_market_tasks.zig",
        "shared/companion/pet_zip.zig",
        "shared/companion/pet_resources.zig",
        "shared/companion/pet_decode_task.zig",
        "shared/companion/pet_async_bridge.zig",
        "shared/companion/animation.zig",
        "shared/companion/native_dispatch.zig",
    };
    const test_step = b.step("test", "Run native ABI, wrapper and lifecycle regression tests");
    const companion_tests = b.step("test-companion", "Run companion unit and shared runtime tests");
    const vcs_tests = b.step("test-vcs", "Run VCS unit and shared runtime tests");
    const test_desktop_digest = b.addOptions();
    test_desktop_digest.addOption([]const u8, "sha256", "");
    const share_tests = b.step("test-share", "Run Share transfer and native UI foundation tests");
    for (test_sources) |source| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = host_modules.imports(),
            }),
        });
        if (std.mem.eql(u8, source, "extensions/share/main.zig")) {
            unit_tests.root_module.addImport("share_config", share_config);
            unit_tests.root_module.addOptions("share_desktop_digest", test_desktop_digest);
        }
        if (std.mem.eql(u8, source, "extensions/vcs-panel/main.zig")) unit_tests.root_module.addImport("vcs_native_source", locked_source);
        const run = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run.step);
        if (std.mem.startsWith(u8, source, "shared/share/") or std.mem.startsWith(u8, source, "extensions/share/"))
            share_tests.dependOn(&run.step);
        const runtime = std.mem.startsWith(u8, source, "shared/runtime/") or std.mem.startsWith(u8, source, "shared/process/");
        if (runtime or std.mem.startsWith(u8, source, "shared/companion/") or std.mem.eql(u8, source, "extensions/companion/main.zig") or std.mem.eql(u8, source, "shared/companion_extension.zig"))
            companion_tests.dependOn(&run.step);
        if (runtime or std.mem.startsWith(u8, source, "shared/vcs/") or std.mem.startsWith(u8, source, "extensions/vcs-panel/"))
            vcs_tests.dependOn(&run.step);
    }
}

/// Build-time validation for approved-digest options: exactly 64 hex characters.
fn isHexDigest(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
