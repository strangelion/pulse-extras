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
    all: [31]std.Build.Module.Import = undefined,

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
        var modules = Modules{ .raw = raw, .abi = abi, .host = host, .commands = commands, .context = context_mod, .ui_model = ui_model, .ui_mount = ui_mount, .diagnostics = diagnostics, .process = process_mod, .text = text_mod, .vcs_capabilities = vcs_capabilities, .vcs_identity = vcs_identity, .vcs_risk = vcs_risk, .vcs_detect = vcs_detect, .vcs_provider = vcs_provider, .vcs_cli = vcs_cli, .vcs_snapshot = vcs_snapshot, .vcs_git = vcs_git, .vcs_jj = vcs_jj, .vcs_svn = vcs_svn };
        modules.all = .{
            .{ .name = "pulse_raw", .module = raw },
            .{ .name = "pulse_abi", .module = abi },
            .{ .name = "pulse_host", .module = host },
            .{ .name = "pulse_commands", .module = commands },
            .{ .name = "pulse_context", .module = context_mod },
            .{ .name = "pulse_ui_model", .module = ui_model },
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
            .{ .name = "vcs_git", .module = vcs_git },
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

    // Standalone companion uses the existing GNU Windows native ABI.
    // Explicit step: no demo in the default production DLL install.
    const pet_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    var pet_modules = Modules.add(b, pet_target, optimize, vcs_test_config);
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
        },
    });
    for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32", "windowscodecs", "uuid", "advapi32" }) |lib|
        pet_root.linkSystemLibrary(lib, .{});
    // Explicit experimental backend. The default WIC build is unchanged.
    if (b.option(bool, "pet-libwebp", "Use the pinned static WebP decoder for pet-demo") orelse false) {
        const source = b.path("zig-out/deps/libwebp-1.6.0");
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
                "src/utils/random_utils.c",      "src/utils/thread_utils.c",           "src/utils/utils.c",
            },
            .flags = &.{"-DWEBP_DSP_OMIT_C_CODE=0"},
        });
    }
    const pet = b.addExecutable(.{ .name = "pulse-pet-demo", .root_module = pet_root });
    const pet_step = b.step("pet-demo", "Build and install the experimental standalone Windows companion");
    pet_step.dependOn(&b.addInstallArtifact(pet, .{}).step);

    // Every module also runs its own tests on the host target, so the wrappers
    // are checked even when the probe does not use them yet.
    var host_modules = Modules.add(b, b.graph.host, .Debug, vcs_test_config);
    const test_sources = [_][]const u8{
        "extensions/abi-probe/main.zig",
        "extensions/hello-panel/main.zig",
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
        "shared/pulse/ui_mount.zig",
        "shared/vcs/capabilities.zig",
        "shared/vcs/identity.zig",
        "shared/vcs/risk.zig",
        "shared/vcs/detect.zig",
        "shared/vcs/provider.zig",
        "shared/vcs/cli.zig",
        "shared/vcs/snapshot.zig",
        "shared/vcs/session.zig",
        "shared/vcs/providers/git.zig",
        "shared/vcs/providers/jj.zig",
        "shared/vcs/providers/svn.zig",
        "shared/companion/openpets_protocol.zig",
        "shared/companion/openpets_lease.zig",
        "shared/companion/behavior.zig",
        "shared/companion/pet_assets.zig",
        "shared/companion/pet_activities.zig",
        "shared/companion/pet_wardrobe.zig",
        "shared/companion/pet_package.zig",
        "shared/companion/pet_memory.zig",
        "shared/companion/pet_resources.zig",
        "shared/companion/pet_decode_task.zig",
        "shared/companion/pet_async_bridge.zig",
        "shared/companion/animation.zig",
        "shared/companion/native_dispatch.zig",
    };
    const test_step = b.step("test", "Run native ABI, wrapper and lifecycle regression tests");
    const companion_tests = b.step("test-companion", "Run companion unit and shared runtime tests");
    const vcs_tests = b.step("test-vcs", "Run VCS unit and shared runtime tests");
    for (test_sources) |source| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = host_modules.imports(),
            }),
        });
        const run = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run.step);
        const runtime = std.mem.startsWith(u8, source, "shared/runtime/") or std.mem.startsWith(u8, source, "shared/process/");
        if (runtime or std.mem.startsWith(u8, source, "shared/companion/"))
            companion_tests.dependOn(&run.step);
        if (runtime or std.mem.startsWith(u8, source, "shared/vcs/"))
            vcs_tests.dependOn(&run.step);
    }
}
