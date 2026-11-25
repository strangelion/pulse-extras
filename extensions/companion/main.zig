//! Experimental native Companion settings contribution. All SDK calls
//! are on the UI thread. Inventory reads and writes use host tasks.
const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const ui = @import("pulse_ui_model");
const mount = @import("pulse_ui_mount");
const diag = @import("pulse_diagnostics");
const library = @import("companion_library");
const config = @import("companion_config");
const pickers = @import("pulse_pickers");
const dialogs_v2 = @import("pulse_dialogs_v2");
const builtin = @import("builtin");

const TimerCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) void;
const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn CreateThreadpoolTimer(TimerCallback, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetThreadpoolTimer(*anyopaque, ?*const FileTime, u32, u32) callconv(.winapi) void;
extern "kernel32" fn WaitForThreadpoolTimerCallbacks(*anyopaque, i32) callconv(.winapi) void;
extern "kernel32" fn CloseThreadpoolTimer(*anyopaque) callconv(.winapi) void;

const allocator = std.heap.page_allocator;
const title = "Pulse Companion";
const preference = "market.downloadConcurrency";
const Section = enum { library, running, market, global };
const TaskKind = enum { runtime_check, builtin_session };
const names = [_][]const u8{ "素材库", "运行管理", "在线市场", "全局设置" };
const commands = [_][]const u8{ "companion.library", "companion.running", "companion.market", "companion.global", "companion.settings.refresh", "companion.download.less", "companion.download.more", "companion.library.reload", "companion.library.poll", "companion.library.previous", "companion.library.next", "companion.library.favorites", "companion.running.start", "companion.running.stop", "companion.running.stop-one", "companion.library.start", "companion.library.favorite-toggle", "companion.library.tag-add", "companion.library.tag-remove", "companion.library.import", "companion.library.import-cancel", "companion.library.browse", "companion.library.recovery-scan", "companion.library.remove", "companion.library.restore", "companion.quarantine.previous", "companion.quarantine.next", "companion.quarantine.purge", "companion.library.search-clear" };

const Instance = struct {
    host: host_mod.Host,
    pages: ?raw.PulseSettingsPagesV1 = null,
    page: u64 = 0,
    panel: ?ui.Panel = null,
    resources: ?raw.PulseResourcesV1 = null,
    pending: u64 = 0,
    pending_operation: u32 = 0,
    subscriptions: [commands.len]u64 = @splat(0),
    section: Section = .library,
    saved: u8 = 4,
    version: u64 = 0,
    loaded: bool = false,
    active: bool = false,
    tasks: ?raw.PulseTasksV1 = null,
    dispatch: ?raw.PulseDispatchV1 = null,
    timer: ?*anyopaque = null,
    queued: std.atomic.Value(bool) = .init(false),
    posting: std.atomic.Value(bool) = .init(false),
    dispatch_token: std.atomic.Value(u64) = .init(0),
    task_id: u64 = 0,
    runtime_task_id: u64 = 0,
    task_kind: TaskKind = .runtime_check,
    runtime_task_state: u32 = raw.PULSE_TASK_RUNNING,
    runtime_done: std.atomic.Value(bool) = .init(false),
    runtime_error: ?anyerror = null,
    runtime_status: []const u8 = if (config.runtime_sha256.len == 0) "未打包运行时；无法启动桌宠" else "切换至运行管理时检查同包运行时",
    runtime_checked: bool = false,
    session: library.Session = .{},
    running_rows: library.RunningSnapshot = .{},
    stop_requested: bool = false,
    task_state: u32 = raw.PULSE_TASK_RUNNING,
    work_done: std.atomic.Value(bool) = .init(false),
    work_error: ?anyerror = null,
    preference_edit: ?library.PreferenceEdit = null,
    import_request: ?library.ImportRequest = null,
    import_result: ?library.ImportResult = null,
    import_dialog: u64 = 0,
    removal_dialog: u64 = 0,
    removal_request: ?library.RemovalRequest = null,
    removal_committed: bool = false,
    picker: ?pickers.Table = null,
    picker_api: ?pickers.Table = null,
    dialog_v2_table: ?dialogs_v2.Table = null,
    dialog_command_subscription: u64 = 0,
    dialog_picker_disabled: bool = false,
    picker_for_dialog: bool = false,
    picker_request: u64 = 0,
    fallback_pick: bool = false,
    recovery_scan: bool = false,
    work_recovery_report: ?library.RecoverySnapshot = null,
    recovery_report: ?library.RecoverySnapshot = null,
    quarantine_offset: usize = 0,
    picked_folder: ?library.PickedFolder = null,
    dialogs: ?raw.PulseDialogsV1 = null,
    import_cancel_requested: bool = false,
    work_snapshot: library.Snapshot = .{},
    library_snapshot: library.Snapshot = .{},
    library_loaded: bool = false,
    library_status: []const u8 = "准备读取本地素材清单",
    library_offset: usize = 0,
    query: [256]u8 = undefined,
    query_len: usize = 0,
    // Editable state belongs to the UI thread. query is frozen while the
    // existing library worker owns it.
    search_draft: [256]u8 = undefined,
    search_draft_len: usize = 0,
    search_revision: u64 = 0,
    search_pending: bool = false,
    search_ticks: u8 = 0,
    search_events: ?raw.PulseUiEventsV1 = null,
    search_token: u64 = 0,
    favorites_only: bool = false,
    status: []const u8 = "设置尚未读取",
};

const Content = struct {
    declared: [commands.len]abi.StringView = undefined,
    navigation: [4]ui.Node = undefined,
    children: [32]ui.Node = undefined,
    removal_toolbar: [2]ui.Node = undefined,
    import_toolbar: [3]ui.Node = undefined,
    toolbar: [4]ui.Node = undefined,
    paging: [2]ui.Node = undefined,
    states: [5]ui.State = undefined,
    preference_toolbar: [4]ui.Node = undefined,
    asset_toolbar: [2]ui.Node = undefined,
    stop_toolbar: [2]ui.Node = undefined,
    row_text: [16][384]u8 = undefined,
    row_ids: [16][64]u8 = undefined,
    dynamic_ids: [4][64]u8 = undefined,
    library_count: [160]u8 = undefined,
    recovery_text: [1024]u8 = undefined,
    quarantine_nodes: [7]ui.Node = undefined,
    cleanup_toolbar: [2]ui.Node = undefined,
    quarantine_paging: [2]ui.Node = undefined,
    quarantine_heading: [160]u8 = undefined,
    quarantine_heading_id: [64]u8 = undefined,
    quarantine_text: [4][224]u8 = undefined,
    quarantine_ids: [4][64]u8 = undefined,
    root: ui.Node = undefined,
    value: [256]u8 = undefined,
};

fn label(id: []const u8, body: []const u8) ui.Node {
    var node = ui.text(body);
    node.id = abi.view(id);
    return node;
}

// Older host renderers retain a text control when its ID is unchanged.
// Give changed text a new identity, while preserving interactive state IDs.
fn changingLabel(buffer: []u8, prefix: []const u8, body: []const u8) ui.Node {
    const id = std.fmt.bufPrint(buffer, "{s}-{x}", .{ prefix, std.hash.Wyhash.hash(0, body) }) catch unreachable;
    return label(id, body);
}

fn action(id: []const u8, body: []const u8, command: []const u8, enabled: bool) ui.Node {
    var node = ui.button(body, command);
    node.id = abi.view(id);
    node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
    return node;
}

fn horizontal(id: []const u8, children: []const ui.Node) ui.Node {
    var node = ui.node(ui.NodeKind.stack);
    node.id = abi.view(id);
    node.orientation = .{ .present = 1, .value = abi.view("horizontal") };
    node.gap = .{ .present = 1, .value = 6 };
    ui.withChildren(&node, children);
    return node;
}

// Build a contiguous prefix: the nested-picker route omits the standalone
// Browse button, so Cancel must occupy the next initialized slot.
fn fillImportToolbar(nodes: *[3]ui.Node, embedded_picker: bool, enabled: bool, importing: bool, can_cancel: bool) []const ui.Node {
    nodes[0] = action("library.import", "导入本地素材", commands[19], enabled);
    var count: usize = 1;
    if (!embedded_picker) {
        nodes[count] = action("library.browse", "浏览文件夹", commands[21], enabled);
        count += 1;
    }
    if (importing) {
        nodes[count] = action("library.import-cancel", "取消导入", commands[20], can_cancel);
        count += 1;
    }
    return nodes[0..count];
}

fn recoveryText(report: library.RecoveryReport, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "最近一次只读扫描：已登记 {d} · 缺失 {d} · 孤立目录 {d} · 待处理目录 {d} · 待处理记录 {d} · 孤立偏好 {d} · 无效项 {d} · 未知项 {d} · 未预留 ID {d} · 隔离待恢复 {d} · 未登记保留 {d}。隔离逻辑字节：待恢复 {d} B · 未登记 {d} B · 未统计目录 {d}。凭证 {d} · 待处理凭证 {d} · 清理标记 {d} · 待处理清理 {d}。未验证文件内容，未执行清理。", .{ report.registered, report.missing, report.orphan_packages, report.pending_directories, report.pending_records, report.orphan_preferences, report.invalid, report.unknown, report.unreserved, report.quarantined_registered, report.quarantined_removed, report.quarantine_registered_bytes, report.quarantine_removed_bytes, report.quarantine_unmeasured, report.receipts, report.receipt_pending, report.cleanup_markers, report.cleanup_pending });
}

fn recoverySuffix(snapshot: *const library.RecoverySnapshot, id: u64) []const u8 {
    return switch (snapshot.stateFor(id) orelse return "") {
        .normal => " · 扫描：目录在位",
        .interrupted_removal => " · 扫描：隔离待恢复",
        .missing => " · 扫描：目录缺失",
        .blocked => " · 扫描：需检查",
    };
}

const quarantine_page_size = 4;

fn quarantineText(detail: library.QuarantineDetail, buffer: []u8) ![]const u8 {
    const state: []const u8 = switch (detail.state) {
        .interrupted_removal => "登记未移除，待恢复",
        .unregistered_retained => "未登记保留（来源未证实）",
        .blocked => "异常，需人工检查",
    };
    const evidence: []const u8 = switch (detail.receipt_state) {
        .absent => "",
        .matched_identity => " · 凭证身份匹配",
        .invalid => " · 凭证异常",
        .unavailable => " · 凭证未验证",
        .cleanup_started => " · 清理事务未确认，禁止重试",
    };
    if (detail.logical_bytes) |bytes| return std.fmt.bufPrint(buffer, "#{d} · {s}{s} · {d} B", .{ detail.id, state, evidence, bytes });
    return std.fmt.bufPrint(buffer, "#{d} · {s}{s} · 大小未统计", .{ detail.id, state, evidence });
}

fn fillQuarantine(report: *const library.RecoverySnapshot, offset: usize, content: *Content, enabled: bool) ui.Node {
    const start = @min(offset, report.quarantine_count);
    const end = @min(start + quarantine_page_size, report.quarantine_count);
    const heading = std.fmt.bufPrint(&content.quarantine_heading, "隔离区：{d} 项 · 显示 {d}–{d} · 列表未收录 {d} 项", .{ report.quarantine_total, if (start == end) 0 else start + 1, end, report.quarantine_total - report.quarantine_count }) catch unreachable;
    content.quarantine_nodes[0] = changingLabel(&content.quarantine_heading_id, "quarantine.heading", heading);
    var count: usize = 1;
    for (report.quarantine[start..end], 0..) |detail, n| {
        const body = quarantineText(detail, &content.quarantine_text[n]) catch unreachable;
        const id = std.fmt.bufPrint(&content.quarantine_ids[n], "quarantine-{x}-{x}", .{ detail.id, std.hash.Wyhash.hash(0, body) }) catch unreachable;
        content.quarantine_nodes[count] = label(id, body);
        count += 1;
    }
    if (report.quarantine_count > quarantine_page_size) {
        content.quarantine_paging[0] = action("quarantine.previous", "上一组", commands[25], start >= quarantine_page_size);
        content.quarantine_paging[1] = action("quarantine.next", "下一组", commands[26], end < report.quarantine_count);
        content.quarantine_nodes[count] = horizontal("quarantine.paging", &content.quarantine_paging);
        count += 1;
    }
    var eligible = false;
    for (report.quarantine[0..report.quarantine_count]) |*detail| {
        if (library.RemovalRequest.initCleanup(detail)) |_| {
            eligible = true;
            break;
        } else |_| {}
    }
    if (eligible) {
        content.cleanup_toolbar[0] = ui.node(ui.NodeKind.text_input);
        content.cleanup_toolbar[0].id = abi.view("quarantine.id");
        content.cleanup_toolbar[0].state = .{ .present = 1, .value = abi.view("quarantine.id") };
        content.cleanup_toolbar[0].placeholder = .{ .present = 1, .value = abi.view("输入隔离素材 ID") };
        content.cleanup_toolbar[1] = action("quarantine.purge", "永久清理", commands[27], enabled);
        content.quarantine_nodes[count] = horizontal("quarantine.cleanup", &content.cleanup_toolbar);
        count += 1;
    }
    var node = ui.node(ui.NodeKind.stack);
    node.id = abi.view("library.quarantine-list");
    node.gap = .{ .present = 1, .value = 6 };
    ui.withChildren(&node, content.quarantine_nodes[0..count]);
    return node;
}

fn fill(instance: *const Instance, content: *Content, tree: *ui.Tree) void {
    for (commands, 0..) |command, n| content.declared[n] = abi.view(command);
    const selected: usize = @backingInt(instance.section);
    for (names, 0..) |name, n| {
        content.navigation[n] = action(commands[n], name, commands[n], n != selected);
    }
    var navigation = ui.node(ui.NodeKind.stack);
    navigation.id = abi.view("navigation");
    navigation.orientation = .{ .present = 1, .value = abi.view("horizontal") };
    navigation.gap = .{ .present = 1, .value = 6 };
    ui.withChildren(&navigation, &content.navigation);
    content.children[0] = navigation;
    content.children[1] = label(commands[selected][10..], names[selected]);
    content.children[1].role = .{ .present = 1, .value = abi.view("section") };
    var count: usize = 3;
    switch (instance.section) {
        .library => {
            content.children[2] = changingLabel(&content.dynamic_ids[0], "library.status", instance.library_status);
            // Standalone full-width native input, not a label beside a
            // narrow field. Host chooses theme, font and icon rendering.
            content.children[3] = ui.node(ui.NodeKind.text_input);
            content.children[3].id = abi.view("library.query");
            content.children[3].placeholder = .{ .present = 1, .value = abi.view("搜索素材来源 ID、编号或标签") };
            content.children[3].glyph = .{ .present = 1, .value = abi.view("search") };
            content.children[3].state = .{ .present = 1, .value = abi.view("library.query") };
            content.children[3].flex = .{ .present = 1, .value = 1 };
            const idle = instance.tasks != null and instance.task_id == 0;
            content.toolbar[0] = action("library.reload", if (instance.search_token != 0 and instance.dispatch != null) "刷新素材库" else "搜索", commands[7], idle);
            content.toolbar[1] = action(if (instance.favorites_only) "library.favorites.on" else "library.favorites.off", if (instance.favorites_only) "仅收藏：开" else "仅收藏：关", commands[11], idle);
            const can_clear = if (instance.panel) |panel| panel.table.set_states != null else false;
            content.toolbar[2] = action("library.search-clear", "清空搜索", commands[28], idle and can_clear);
            const fallback = instance.task_id != 0 and instance.timer == null;
            content.toolbar[3] = action("library.poll", "手动检查", commands[8], fallback);
            content.children[4] = horizontal("library.toolbar", content.toolbar[0..if (fallback) @as(usize, 4) else 3]);
            count = 5;
            if (instance.library_loaded) {
                const snapshot = &instance.library_snapshot;
                const end = @min(snapshot.count, instance.library_offset + 16);
                const line = std.fmt.bufPrint(&content.library_count, "共 {d} 项 · 匹配 {d} 项 · 显示 {d}–{d}", .{ snapshot.total, snapshot.count, if (snapshot.count == 0) 0 else instance.library_offset + 1, end }) catch unreachable;
                content.children[5] = changingLabel(&content.dynamic_ids[1], "library.count", line);
                count = 6;
                if (snapshot.count == 0) {
                    content.children[count] = if (snapshot.total == 0) label("library.empty", "暂无本地素材；打包运行时后可导入。") else label("library.no-match", "没有匹配的素材，请调整搜索条件。");
                    count += 1;
                }
                if (snapshot.count > 16) {
                    content.paging[0] = action("library.previous", "上一页", commands[9], instance.library_offset > 0);
                    content.paging[1] = action("library.next", "下一页", commands[10], end < snapshot.count);
                    content.children[count] = horizontal("library.pagination", &content.paging);
                    count += 1;
                }
                if (config.helper_sha256.len == 64 and snapshot.count != 0) {
                    content.asset_toolbar[0] = ui.node(ui.NodeKind.text_input);
                    content.asset_toolbar[0].id = abi.view("library.asset-id");
                    content.asset_toolbar[0].state = .{ .present = 1, .value = abi.view("library.asset-id") };
                    content.asset_toolbar[0].placeholder = .{ .present = 1, .value = abi.view("输入素材 ID") };
                    const live = instance.runtime_task_id != 0 and instance.task_kind == .builtin_session;
                    content.asset_toolbar[1] = action("library.start", "启动指定素材", commands[15], instance.preference_edit == null and !instance.stop_requested and (instance.runtime_task_id == 0 or (live and instance.session.canStart())));
                    content.children[count] = horizontal("library.start-toolbar", &content.asset_toolbar);
                    count += 1;
                    const edit_enabled = config.runtime_sha256.len == 64 and instance.task_id == 0 and instance.runtime_task_id == 0 and instance.tasks != null;
                    content.preference_toolbar[0] = ui.node(ui.NodeKind.text_input);
                    content.preference_toolbar[0].id = abi.view("library.tag");
                    content.preference_toolbar[0].state = .{ .present = 1, .value = abi.view("library.tag") };
                    content.preference_toolbar[0].placeholder = .{ .present = 1, .value = abi.view("标签（最多 64 字节）") };
                    content.preference_toolbar[1] = action("library.favorite-toggle", "切换收藏", commands[16], edit_enabled);
                    content.preference_toolbar[2] = action("library.tag-add", "添加标签", commands[17], edit_enabled);
                    content.preference_toolbar[3] = action("library.tag-remove", "移除标签", commands[18], edit_enabled);
                    content.children[count] = horizontal("library.preferences", &content.preference_toolbar);
                    count += 1;
                }
                for (snapshot.rows[instance.library_offset..end], 0..) |*row, n| {
                    const suffix = if (instance.recovery_report) |*report| recoverySuffix(report, row.id) else "";
                    const body = std.fmt.bufPrint(&content.row_text[n], "#{d}  {s} · {s} · {s} · 标签 {d} {s}{s}", .{ row.id, row.sourceId(), if (row.paired) "双摘要记录" else "待重验", if (row.favorite) "已收藏" else "未收藏", row.tag_count, row.first_tag[0..row.first_tag_len], suffix }) catch unreachable;
                    const id = std.fmt.bufPrint(&content.row_ids[n], "asset-{x}-{x}", .{ row.id, std.hash.Wyhash.hash(0, body) }) catch unreachable;
                    content.children[count] = label(id, body);
                    count += 1;
                }
            }
            if (instance.dialogs != null and config.helper_sha256.len == 64 and config.runtime_sha256.len == 64) {
                const enabled = instance.tasks != null and instance.dispatch != null and instance.task_id == 0 and instance.runtime_task_id == 0 and instance.import_dialog == 0 and instance.picker_request == 0;
                const embedded_picker = instance.dialog_v2_table != null and instance.picker_api != null and !instance.dialog_picker_disabled;
                const buttons = fillImportToolbar(&content.import_toolbar, embedded_picker, enabled, instance.import_request != null, instance.task_id != 0 and !instance.import_cancel_requested);
                content.children[count] = horizontal("library.import-toolbar", buttons);
                count += 1;
            }
            if (config.runtime_sha256.len == 64) {
                const can_scan = instance.tasks != null and instance.dispatch != null and instance.task_id == 0 and instance.runtime_task_id == 0 and instance.import_dialog == 0 and instance.picker_request == 0;
                content.children[count] = action("library.recovery-scan", "扫描恢复状态（只读）", commands[22], can_scan);
                count += 1;
            }
            if (instance.recovery_report) |*report| {
                const body = recoveryText(report.summary, &content.recovery_text) catch unreachable;
                content.children[count] = changingLabel(&content.dynamic_ids[2], "library.recovery-report", body);
                count += 1;
                if (report.quarantine_total != 0) {
                    content.children[count] = fillQuarantine(report, instance.quarantine_offset, content, canMaintain(instance));
                    count += 1;
                }
                if (instance.library_loaded and instance.library_snapshot.count != 0 and instance.dialogs != null and config.runtime_sha256.len == 64 and config.helper_sha256.len == 64) {
                    const enabled = canMaintain(instance);
                    content.removal_toolbar[0] = action("library.remove", "隔离移除指定素材", commands[23], enabled);
                    content.removal_toolbar[1] = action("library.restore", "恢复中断移除", commands[24], enabled);
                    content.children[count] = horizontal("library.removal-toolbar", &content.removal_toolbar);
                    count += 1;
                }
            }
        },
        .running => {
            content.children[2] = changingLabel(&content.dynamic_ids[0], "running.status", instance.runtime_status);
            const live = instance.runtime_task_id != 0 and instance.task_kind == .builtin_session;
            const can_start = config.runtime_sha256.len == 64 and config.helper_sha256.len == 64 and !instance.stop_requested and ((instance.runtime_task_id == 0 and instance.runtime_checked) or (live and instance.session.canStart()));
            content.toolbar[0] = action("running.start", if (live) "再启动内置桌宠" else "启动内置桌宠", commands[12], can_start);
            content.toolbar[1] = action("running.stop", "停止全部桌宠", commands[13], live and !instance.stop_requested);
            content.children[3] = horizontal("running.toolbar", content.toolbar[0..2]);
            count = 4;
            if (live) {
                const phase: library.Phase = @fromBackingInt(@intCast(instance.session.phase.load(.acquire)));
                const rejection: library.Rejection = @fromBackingInt(@intCast(instance.session.last_rejection.load(.acquire)));
                const reason: []const u8 = switch (rejection) {
                    .none => "",
                    .capacity => " · 资源预算不足",
                    .unverified => " · 摘要验证未通过",
                    .private_root => " · 私有目录不可用",
                    .unknown_asset => " · 素材不存在",
                    .launch_failed => " · 启动失败",
                    .unknown_instance => " · 实例已退出",
                    .child_exit => " · 实例异常退出",
                };
                const status = std.fmt.bufPrint(&content.value, "{s} · 运行 {d}/{d} · 异常 {d} · 工作集 {d} KiB · 私有内存 {d} KiB{s}", .{ switch (phase) {
                    .idle => "等待任务",
                    .starting => "启动中",
                    .running => "首帧已确认",
                    .stopping => "正在退出",
                }, instance.session.ready.load(.acquire), instance.session.owned.load(.acquire), instance.session.denied.load(.acquire), instance.session.working_set.load(.acquire) / 1024, instance.session.private_bytes.load(.acquire) / 1024, reason }) catch unreachable;
                content.children[4] = changingLabel(&content.dynamic_ids[1], "running.metrics", status);
                count = 5;
                if (instance.running_rows.count != 0) {
                    content.stop_toolbar[0] = ui.node(ui.NodeKind.text_input);
                    content.stop_toolbar[0].id = abi.view("running.stop-id");
                    content.stop_toolbar[0].state = .{ .present = 1, .value = abi.view("running.stop-id") };
                    content.stop_toolbar[0].placeholder = .{ .present = 1, .value = abi.view("输入实例 ID") };
                    const can_stop = !instance.stop_requested and instance.session.pending_stop.load(.acquire) == 0 and instance.session.stopping_id.load(.acquire) == 0 and phase == .running and !instance.session.pending_start.load(.acquire);
                    content.stop_toolbar[1] = action("running.stop-one", "停止指定实例", commands[14], can_stop);
                    content.children[count] = horizontal("running.stop-toolbar", &content.stop_toolbar);
                    count += 1;
                    for (instance.running_rows.rows[0..instance.running_rows.count], 0..) |item, n| {
                        const state = switch (item.state) {
                            .starting => "启动中",
                            .running => "运行中",
                            .stopping => "正在退出",
                        };
                        const body = if (item.metrics) |metrics| blk: {
                            if (metrics.cpu_core_percent) |cpu| {
                                break :blk std.fmt.bufPrint(&content.row_text[n], "ID {d} · {s} · PID {d} · CPU {d:.1}% · 工作集 {d} KiB · 私有 {d} KiB · 句柄 {d}", .{ item.id, state, metrics.pid, cpu, metrics.working_set / 1024, metrics.private_bytes / 1024, metrics.handles }) catch unreachable;
                            }
                            break :blk std.fmt.bufPrint(&content.row_text[n], "ID {d} · {s} · PID {d} · CPU — · 工作集 {d} KiB · 私有 {d} KiB · 句柄 {d}", .{ item.id, state, metrics.pid, metrics.working_set / 1024, metrics.private_bytes / 1024, metrics.handles }) catch unreachable;
                        } else std.fmt.bufPrint(&content.row_text[n], "ID {d} · {s} · 暂无资源采样", .{ item.id, state }) catch unreachable;
                        const id = std.fmt.bufPrint(&content.row_ids[n], "instance-{x}-{x}", .{ item.id, std.hash.Wyhash.hash(0, body) }) catch unreachable;
                        content.children[count] = label(id, body);
                        count += 1;
                    }
                }
            }
        },
        .market => content.children[2] = label("market.status", "市场服务已独立实现，尚未连接宿主工作线程。搜索、下载和安装暂不可用。"),
        .global => {
            const value = if (instance.loaded) std.fmt.bufPrint(&content.value, "已保存的下载并发偏好：{d}（1–8）", .{instance.saved}) catch unreachable else "下载并发偏好尚未确认";
            content.children[2] = changingLabel(&content.dynamic_ids[2], "settings.value", value);
            content.children[3] = changingLabel(&content.dynamic_ids[3], "settings.status", instance.status);
            content.toolbar[0] = action("settings.refresh", "重新读取", commands[4], instance.resources != null and instance.pending == 0);
            content.toolbar[1] = action("settings.less", "减少并发", commands[5], instance.loaded and instance.pending == 0 and instance.saved > 1);
            content.toolbar[2] = action("settings.more", "增加并发", commands[6], instance.loaded and instance.pending == 0 and instance.saved < 8);
            content.children[4] = horizontal("settings.toolbar", content.toolbar[0..3]);
            count = 5;
        },
    }
    content.root = ui.node(ui.NodeKind.stack);
    content.root.id = abi.view("companion.root");
    content.root.gap = .{ .present = 1, .value = 8 };
    ui.withChildren(&content.root, content.children[0..count]);
    tree.* = std.mem.zeroes(ui.Tree);
    tree.size = @sizeOf(ui.Tree);
    tree.root = &content.root;
    tree.commands = &content.declared;
    tree.command_count = content.declared.len;
    content.states[0] = .{ .key = abi.view("library.query"), .value = abi.view(instance.search_draft[0..instance.search_draft_len]) };
    content.states[1] = .{ .key = abi.view("running.stop-id"), .value = abi.view("") };
    content.states[2] = .{ .key = abi.view("library.asset-id"), .value = abi.view("") };
    content.states[3] = .{ .key = abi.view("library.tag"), .value = abi.view("") };
    content.states[4] = .{ .key = abi.view("quarantine.id"), .value = abi.view("") };
    tree.states = &content.states;
    tree.state_count = content.states.len;
}

fn refresh(instance: *Instance) void {
    if (!instance.active) return;
    if (instance.panel) |*panel| {
        var content: Content = undefined;
        var tree: ui.Tree = undefined;
        fill(instance, &content, &tree);
        panel.update(&tree) catch |err| diag.status("companion-update-failed", @intFromError(err));
    }
}

fn readPreference(settings: raw.PulseSettings) !u8 {
    if (settings.version > (1 << 53) - 1 or settings.count > 1024 or (settings.count != 0 and settings.values == null)) return error.InvalidSettings;
    var found: ?u8 = null;
    for (0..settings.count) |n| {
        const pair = settings.values[n];
        const key = abi.slice(pair.key) orelse continue;
        if (!std.mem.eql(u8, key, preference)) continue;
        if (found != null) return error.InvalidSettings;
        const value = abi.slice(pair.value) orelse return error.InvalidSettings;
        if (value.len != 1 or value[0] < '1' or value[0] > '8') return error.InvalidSettings;
        found = value[0] - '0';
    }
    return found orelse 4;
}

fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (reply == null or reply[0].size < @sizeOf(raw.PulseResourcesReply) or instance.pending == 0 or reply[0].request_id != instance.pending) return;
    const operation = instance.pending_operation;
    instance.pending = 0;
    instance.pending_operation = 0;
    instance.loaded = false;
    if (!instance.active) return;
    const value = &reply[0];
    if (value.operation != operation or value.status != abi.ok) {
        instance.status = "设置读取或写入失败；请重新读取（可能存在版本冲突）";
    } else if (readPreference(value.settings)) |saved| {
        instance.saved = saved;
        instance.version = value.settings.version;
        instance.loaded = true;
        instance.status = if (operation == raw.PULSE_RESOURCES_SETTINGS_SET) "偏好已确认保存；尚未连接实际下载运行时" else "已读取设置（未配置时采用默认值）；尚未连接实际下载运行时";
    } else |_| {
        instance.status = "宿主设置数据无效；未覆盖原有设置";
    }
    refresh(instance);
}

fn load(instance: *Instance) void {
    const resources = instance.resources orelse return;
    if (instance.pending != 0) return;
    const get = resources.settings_get orelse return;
    var request: u64 = 0;
    const status = get(resources.context, completed, instance, &request);
    instance.loaded = false;
    if (status == abi.ok and request != 0) {
        instance.pending = request;
        instance.pending_operation = raw.PULSE_RESOURCES_SETTINGS_GET;
        instance.status = "正在读取设置";
    } else {
        instance.status = "无法读取宿主设置";
    }
    refresh(instance);
}

fn save(instance: *Instance, next: u8) void {
    const resources = instance.resources orelse return;
    if (!instance.loaded or instance.pending != 0 or next < 1 or next > 8) return;
    const set = resources.settings_set orelse return;
    const value = [_]u8{'0' + next};
    var request: u64 = 0;
    const status = set(resources.context, abi.view(preference), abi.view(&value), 0, instance.version, completed, instance, &request);
    if (status == abi.ok and request != 0) {
        instance.pending = request;
        instance.pending_operation = raw.PULSE_RESOURCES_SETTINGS_SET;
        instance.status = "正在保存设置";
    } else {
        instance.loaded = false;
        instance.status = "保存请求被拒绝；请重新读取";
    }
    refresh(instance);
}

// Host-owned worker. Writes only the private result buffer; no UI call.
fn readLibrary(user: ?*anyopaque, context: [*c]const raw.PulseTaskContext) callconv(.c) raw.PulseTaskState {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return raw.PULSE_TASK_FAILED));
    defer instance.work_done.store(true, .release);
    diag.event("companion-library-worker-start");
    defer diag.event("companion-library-worker-end");
    if (context == null) return raw.PULSE_TASK_FAILED;
    const canceled = context[0].cancelled orelse return raw.PULSE_TASK_FAILED;
    if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
    if (instance.fallback_pick) {
        instance.picked_folder = library.pickFolderDefault(config.helper_sha256) catch |err| {
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
        if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
        return raw.PULSE_TASK_COMPLETED;
    }
    if (instance.recovery_scan) {
        instance.work_recovery_report = library.scanRecoveryDefault(config.runtime_sha256) catch |err| {
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
        if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
        return raw.PULSE_TASK_COMPLETED;
    }
    if (instance.removal_request) |*request| {
        library.applyRemovalDefault(config.runtime_sha256, request, .{ .callback = canceled, .context = context[0].context }) catch |err| {
            if (err == error.Canceled) return raw.PULSE_TASK_CANCELLED;
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
        instance.removal_committed = true;
    }
    if (instance.preference_edit) |*edit| {
        library.editPreferenceDefault(config.runtime_sha256, edit) catch |err| {
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
    }
    if (instance.import_request) |*request| {
        instance.import_result = library.importDefault(config.runtime_sha256, config.helper_sha256, request, .{ .callback = canceled, .context = context[0].context }) catch |err| {
            if (err == error.Canceled) return raw.PULSE_TASK_CANCELLED;
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
    }
    library.readFilteredDefault(&instance.work_snapshot, .{ .query = instance.query[0..instance.query_len], .favorites_only = instance.favorites_only, .cancel = canceled, .context = context[0].context }) catch |err| {
        if (err == error.Canceled) return raw.PULSE_TASK_CANCELLED;
        instance.work_error = err;
        return raw.PULSE_TASK_FAILED;
    };
    if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
    return raw.PULSE_TASK_COMPLETED;
}

fn checkRuntime(user: ?*anyopaque, context: [*c]const raw.PulseTaskContext) callconv(.c) raw.PulseTaskState {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return raw.PULSE_TASK_FAILED));
    defer instance.runtime_done.store(true, .release);
    if (context == null) return raw.PULSE_TASK_FAILED;
    const canceled = context[0].cancelled orelse return raw.PULSE_TASK_FAILED;
    if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
    library.checkRuntime(config.runtime_sha256) catch |err| {
        instance.runtime_error = err;
        return raw.PULSE_TASK_FAILED;
    };
    return if (canceled(context[0].context) != 0) raw.PULSE_TASK_CANCELLED else raw.PULSE_TASK_COMPLETED;
}

fn runBuiltin(user: ?*anyopaque, context: [*c]const raw.PulseTaskContext) callconv(.c) raw.PulseTaskState {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return raw.PULSE_TASK_FAILED));
    defer instance.runtime_done.store(true, .release);
    if (context == null) return raw.PULSE_TASK_FAILED;
    const canceled = context[0].cancelled orelse return raw.PULSE_TASK_FAILED;
    if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
    library.runBuiltin(&instance.session, config.runtime_sha256, config.helper_sha256, canceled, context[0].context) catch |err| {
        instance.runtime_error = err;
        return raw.PULSE_TASK_FAILED;
    };
    return if (canceled(context[0].context) != 0) raw.PULSE_TASK_CANCELLED else raw.PULSE_TASK_COMPLETED;
}

fn observe(user: ?*anyopaque, snapshot: [*c]const raw.PulseTaskSnapshot) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (snapshot == null or snapshot[0].size < @sizeOf(raw.PulseTaskSnapshot) or snapshot[0].id != instance.task_id) return;
    instance.task_state = snapshot[0].state;
}

fn observeRuntime(user: ?*anyopaque, snapshot: [*c]const raw.PulseTaskSnapshot) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (snapshot == null or snapshot[0].size < @sizeOf(raw.PulseTaskSnapshot) or snapshot[0].id != instance.runtime_task_id) return;
    instance.runtime_task_state = snapshot[0].state;
}

fn dispatchPoll(user: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    instance.queued.store(false, .release);
    if (instance.active) pollTasks(instance);
}

// A Windows threadpool timer only posts to the public host dispatcher.
// Never calls UI/tasks APIs, never waits for UI, and coalesces pending work.
fn timerTick(_: ?*anyopaque, user: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    // A periodic threadpool timer may overlap callbacks. Serialize post
    // itself so an older token cannot overwrite a newer pending token.
    if (instance.posting.swap(true, .acq_rel)) return;
    defer instance.posting.store(false, .release);
    if (instance.queued.swap(true, .acq_rel)) return;
    const dispatch = instance.dispatch orelse {
        instance.queued.store(false, .release);
        return;
    };
    const post = dispatch.post orelse {
        instance.queued.store(false, .release);
        return;
    };
    var token: u64 = 0;
    if (post(dispatch.context, dispatchPoll, instance, &token) != abi.ok or token == 0) {
        instance.queued.store(false, .release);
        return;
    }
    instance.dispatch_token.store(token, .release);
}

fn armTimer(instance: *Instance) void {
    if (comptime builtin.os.tag != .windows) return;
    if (instance.timer != null or instance.dispatch == null) return;
    const timer = CreateThreadpoolTimer(timerTick, instance, null) orelse {
        diag.event("companion-auto-refresh-unavailable");
        return;
    };
    instance.timer = timer;
    // Relative 100 ms; poll no faster than 10 Hz while a task is pending.
    const due: u64 = @bitCast(@as(i64, -1_000_000));
    const time: FileTime = .{ .low = @truncate(due), .high = @truncate(due >> 32) };
    SetThreadpoolTimer(timer, &time, 100, 0);
}

fn stopTimer(instance: *Instance) void {
    if (comptime builtin.os.tag != .windows) return;
    if (instance.timer) |timer| {
        SetThreadpoolTimer(timer, null, 0, 0);
        // Timer callbacks do not wait on the UI thread.
        WaitForThreadpoolTimerCallbacks(timer, 1);
        CloseThreadpoolTimer(timer);
        instance.timer = null;
    }
    const token = instance.dispatch_token.swap(0, .acq_rel);
    if (token != 0) {
        if (instance.dispatch) |dispatch| {
            if (dispatch.cancel) |cancel| _ = cancel(dispatch.context, token);
        }
    }
    instance.queued.store(false, .release);
}

fn terminal(state: u32) bool {
    return state == raw.PULSE_TASK_COMPLETED or state == raw.PULSE_TASK_FAILED or state == raw.PULSE_TASK_CANCELLED or state == raw.PULSE_TASK_PARTIAL;
}

fn pollTasks(instance: *Instance) void {
    pollLibrary(instance);
    pollRuntime(instance);
    pollSearch(instance);
    if (instance.task_id == 0 and instance.runtime_task_id == 0 and !(instance.section == .library and instance.search_pending)) stopTimer(instance);
}

fn validSearch(value: []const u8) bool {
    return value.len <= 256 and std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}

fn rememberSearch(instance: *Instance, value: []const u8) void {
    @memcpy(instance.search_draft[0..value.len], value);
    instance.search_draft_len = value.len;
}

fn applySearch(instance: *Instance) void {
    @memcpy(instance.query[0..instance.search_draft_len], instance.search_draft[0..instance.search_draft_len]);
    instance.query_len = instance.search_draft_len;
    instance.search_pending = false;
    instance.search_ticks = 0;
}

fn onSearchChanged(user: ?*anyopaque, panel: u64, batch: [*c]const raw.PulseUiStateBatch) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!instance.active or panel != instance.page or instance.section != .library or instance.search_token == 0) return;
    if (batch == null or batch[0].changes == null or batch[0].count > 128) return;
    for (0..batch[0].count) |n| {
        const change = batch[0].changes[n];
        if (change.source_mask & @as(u32, raw.PULSE_UI_STATE_USER) == 0 or change.revision <= instance.search_revision) continue;
        const key = abi.slice(change.key) orelse continue;
        if (!std.mem.eql(u8, key, "library.query")) continue;
        instance.search_revision = change.revision;
        const value = abi.slice(change.value) orelse continue;
        if (!validSearch(value)) continue;
        if (std.mem.eql(u8, value, instance.search_draft[0..instance.search_draft_len])) continue;
        rememberSearch(instance, value);
        if (instance.dispatch != null and instance.tasks != null) {
            instance.search_pending = true;
            instance.search_ticks = 3;
            armTimer(instance);
            if (instance.timer == null) instance.search_pending = false;
        }
    }
}

fn pollSearch(instance: *Instance) void {
    if (!instance.active or instance.section != .library or !instance.search_pending) return;
    if (instance.search_ticks != 0) {
        instance.search_ticks -= 1;
        if (instance.search_ticks != 0) return;
    }
    if (instance.task_id != 0 or instance.import_dialog != 0 or instance.removal_dialog != 0 or instance.picker_request != 0) return;
    applySearch(instance);
    startLibrary(instance, false);
}

fn clearSearch(instance: *Instance) void {
    if (instance.task_id != 0 or instance.import_dialog != 0 or instance.removal_dialog != 0 or instance.picker_request != 0) return;
    const panel = if (instance.panel) |*value| value else return;
    const states = [_]ui.State{.{ .key = abi.view("library.query"), .value = abi.view("") }};
    panel.setStates(&states) catch |err| {
        instance.library_status = @errorName(err);
        refresh(instance);
        return;
    };
    rememberSearch(instance, "");
    applySearch(instance);
    startLibrary(instance, false);
}

fn subscribeSearch(instance: *Instance) void {
    var table = std.mem.zeroes(raw.PulseUiEventsV1);
    if (instance.pages) |pages| {
        const query = pages.query orelse return;
        if (query(pages.context, instance.page, abi.view(raw.PULSE_UI_EVENTS_INTERFACE_NAME), raw.PULSE_UI_EVENTS_VERSION_1, &table, @sizeOf(raw.PulseUiEventsV1)) != abi.ok) return;
    } else {
        table = (instance.host.queryOptional(raw.PulseUiEventsV1, raw.PULSE_UI_EVENTS_INTERFACE_NAME, raw.PULSE_UI_EVENTS_VERSION_1) catch return) orelse return;
    }
    if (table.size < @sizeOf(raw.PulseUiEventsV1) or table.version < raw.PULSE_UI_EVENTS_VERSION_1) return;
    const subscribe = table.subscribe_state orelse return;
    _ = table.unsubscribe orelse return;
    var token: u64 = 0;
    if (subscribe(table.context, instance.page, abi.view("library.query"), @intCast(raw.PULSE_UI_STATE_USER), onSearchChanged, instance, &token) != abi.ok or token == 0) return;
    instance.search_events = table;
    instance.search_token = token;
}

fn pollLibrary(instance: *Instance) void {
    const tasks = instance.tasks orelse return;
    if (instance.task_id == 0) return;
    const get = tasks.get orelse return;
    const release = tasks.release orelse return;
    instance.task_state = raw.PULSE_TASK_RUNNING;
    if (get(tasks.context, instance.task_id, observe, instance) != abi.ok) {
        instance.library_status = "无法读取任务状态；保留任务所有权";
        refresh(instance);
        return;
    }
    if (!terminal(instance.task_state)) return;
    if (release(tasks.context, instance.task_id) != abi.ok) {
        instance.library_status = "任务释放失败；请重试";
        refresh(instance);
        return;
    }
    diag.status("companion-library-terminal", instance.task_state);
    instance.task_id = 0;
    if (instance.recovery_scan) {
        instance.recovery_scan = false;
        instance.quarantine_offset = 0;
        const done = instance.work_done.load(.acquire);
        if (instance.task_state == raw.PULSE_TASK_COMPLETED and done and instance.work_error == null and instance.work_recovery_report != null) {
            instance.recovery_report = instance.work_recovery_report;
            instance.library_status = "恢复扫描完成；未修改素材";
        } else {
            instance.recovery_report = null;
            instance.library_status = if (instance.task_state == raw.PULSE_TASK_CANCELLED) "恢复扫描已取消" else if (done) if (instance.work_error) |err| @errorName(err) else "恢复扫描结果无效" else "恢复扫描未完成";
        }
        instance.work_recovery_report = null;
        refresh(instance);
        return;
    }
    if (instance.fallback_pick) {
        instance.fallback_pick = false;
        const done = instance.work_done.load(.acquire);
        if (instance.active and instance.section == .library and instance.runtime_task_id == 0) {
            if (instance.task_state == raw.PULSE_TASK_COMPLETED and done and instance.work_error == null) {
                if (instance.picked_folder) |folder| {
                    var selection: Selection = .{};
                    selection.fromPath(folder.path[0..folder.len]);
                    showImportWithSelection(instance, &selection);
                } else instance.library_status = "已取消文件夹选择";
            } else if (instance.task_state != raw.PULSE_TASK_CANCELLED) {
                instance.library_status = "系统文件夹选择不可用；请手动填写";
                showImportWithSelection(instance, &.{});
            }
        }
        instance.picked_folder = null;
        refresh(instance);
        return;
    }
    const was_edit = instance.preference_edit != null;
    const was_import = instance.import_request != null;
    const removal = instance.removal_request;
    instance.removal_request = null;
    instance.preference_edit = null;
    instance.import_request = null;
    instance.import_cancel_requested = false;
    const done = instance.work_done.load(.acquire);
    if (instance.task_state == raw.PULSE_TASK_COMPLETED and done and instance.work_error == null) {
        instance.library_snapshot = instance.work_snapshot;
        instance.library_loaded = true;
        instance.library_offset = 0;
        instance.library_status = if (removal) |request| (switch (request.action) {
            .quarantine => "素材已隔离移除；文件仍保留",
            .restore_interrupted => "中断移除已恢复；请重新扫描",
            .purge => "隔离素材已永久清理；凭证与事务标记保留",
        }) else if (was_import) (if (instance.import_result != null and instance.import_result.? == .existing) "素材已存在；未重复复制" else "素材已导入并重新读取") else if (was_edit) "偏好已保存并重新读取" else if (instance.library_snapshot.missing) "固定目录中尚无素材清单（未创建文件）" else "已读取持久化清单；尚未验证素材文件";
    } else {
        instance.library_loaded = false;
        instance.library_status = if (removal != null and done and (if (instance.work_error) |err| err == error.RemovalCommittedWithoutReceipt else false)) "移除已提交；凭证写入失败，保留隔离文件，禁止清理" else if (removal != null and done and (if (instance.work_error) |err| err == error.CleanupInterrupted or err == error.CleanupIntentUncertain else false)) "清理事务状态不确定；请重新扫描，禁止自动重试" else if (removal != null and done and instance.removal_committed) "操作已提交；请刷新并重新扫描" else if (removal != null and instance.task_state == raw.PULSE_TASK_CANCELLED) "任务取消；请刷新确认磁盘状态" else if (was_import and done and instance.import_result != null) "导入已提交；请刷新确认库存" else if (instance.task_state == raw.PULSE_TASK_CANCELLED) (if (was_import or was_edit) "任务已取消；请刷新确认磁盘状态" else "读取已取消") else if (done) if (instance.work_error) |err| @errorName(err) else "读取结果无效" else "读取未完成";
    }
    refresh(instance);
}

fn pollRuntime(instance: *Instance) void {
    const tasks = instance.tasks orelse return;
    if (instance.runtime_task_id == 0) return;
    const get = tasks.get orelse return;
    const release = tasks.release orelse return;
    instance.runtime_task_state = raw.PULSE_TASK_RUNNING;
    if (get(tasks.context, instance.runtime_task_id, observeRuntime, instance) != abi.ok) {
        instance.runtime_status = "无法读取运行时任务状态；保留任务所有权";
        refresh(instance);
        return;
    }
    if (!terminal(instance.runtime_task_state)) {
        if (instance.task_kind == .builtin_session) {
            instance.session.copyRows(&instance.running_rows);
            if (instance.section == .running) refresh(instance);
        }
        return;
    }
    if (release(tasks.context, instance.runtime_task_id) != abi.ok) {
        instance.runtime_status = "运行时任务释放失败；请重试";
        refresh(instance);
        return;
    }
    diag.status("companion-runtime-terminal", instance.runtime_task_state);
    instance.runtime_task_id = 0;
    instance.running_rows = .{};
    const done = instance.runtime_done.load(.acquire);
    if (instance.task_kind == .builtin_session) {
        instance.stop_requested = false;
        instance.runtime_status = if (done and instance.runtime_error != null) @errorName(instance.runtime_error.?) else if (instance.runtime_task_state == raw.PULSE_TASK_COMPLETED or instance.runtime_task_state == raw.PULSE_TASK_CANCELLED) "全部桌宠已退出" else "运行任务未完成";
        instance.runtime_checked = done and instance.runtime_error == null;
    } else {
        instance.runtime_checked = instance.runtime_task_state == raw.PULSE_TASK_COMPLETED and done and instance.runtime_error == null;
        instance.runtime_status = if (instance.runtime_checked) "同包运行时已通过检查；可启动内置桌宠" else if (done) if (instance.runtime_error) |err| @errorName(err) else "运行时检查未完成" else "运行时检查已取消";
    }
    refresh(instance);
}

fn startRuntimeCheck(instance: *Instance) void {
    if (!instance.active or config.runtime_sha256.len == 0 or instance.runtime_checked or instance.runtime_task_id != 0 or instance.preference_edit != null or instance.import_request != null or instance.import_dialog != 0 or instance.picker_request != 0 or instance.fallback_pick or instance.recovery_scan or instance.removal_request != null or instance.removal_dialog != 0) return;
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    // Existing dispatcher/timer is required: do not create an uncollectable task.
    if (instance.dispatch == null) {
        instance.runtime_status = "宿主自动刷新不可用；未启动运行时检查";
        return;
    }
    instance.runtime_done.store(false, .release);
    instance.runtime_error = null;
    instance.task_kind = .runtime_check;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view("检查桌宠运行时"),
        .type = abi.view("companion.runtime"),
        .work = checkRuntime,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.runtime_task_id = id;
        instance.runtime_status = "正在验证并打开同包运行时";
        armTimer(instance);
        if (instance.timer == null) instance.runtime_status = "自动收集不可用；切换页面重试检查";
    } else {
        instance.runtime_status = "宿主拒绝运行时检查任务";
    }
    refresh(instance);
}

fn startBuiltin(instance: *Instance) void {
    if (instance.runtime_task_id == 0 and !instance.runtime_checked) return;
    startAsset(instance, library.builtin_asset_id);
}

fn startAsset(instance: *Instance, asset_id: u64) void {
    if (!instance.active or config.runtime_sha256.len != 64 or config.helper_sha256.len != 64 or instance.dispatch == null or instance.stop_requested or instance.preference_edit != null or instance.import_request != null or instance.import_dialog != 0 or instance.picker_request != 0 or instance.fallback_pick or instance.recovery_scan or instance.removal_request != null or instance.removal_dialog != 0 or asset_id == 0) return;
    if (instance.runtime_task_id != 0) {
        if (instance.task_kind != .builtin_session) return;
        instance.runtime_status = if (instance.session.requestAsset(asset_id)) "已提交新增实例请求" else "暂不可新增实例；请等待或停止";
        refresh(instance);
        return;
    }
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    instance.runtime_done.store(false, .release);
    instance.runtime_error = null;
    instance.session.reset();
    instance.session.start_asset.store(asset_id, .release);
    instance.running_rows = .{};
    instance.stop_requested = false;
    instance.task_kind = .builtin_session;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view("运行桌宠"),
        .type = abi.view("companion.session"),
        .work = runBuiltin,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.runtime_task_id = id;
        instance.runtime_status = "桌宠任务已提交";
        armTimer(instance);
        if (instance.timer == null) instance.runtime_status = "自动收集不可用；切换页面重试检查";
    } else {
        instance.runtime_status = "宿主拒绝启动任务";
    }
    refresh(instance);
}

fn stopBuiltin(instance: *Instance) void {
    if (instance.runtime_task_id == 0 or instance.task_kind != .builtin_session or instance.stop_requested) return;
    const tasks = instance.tasks orelse return;
    const cancel = tasks.cancel orelse return;
    if (cancel(tasks.context, instance.runtime_task_id) == abi.ok) {
        instance.stop_requested = true;
        instance.runtime_status = "已请求停止全部桌宠；等待实际退出";
    } else {
        instance.runtime_status = "停止请求未确认";
    }
    refresh(instance);
}

fn stopOne(instance: *Instance) void {
    if (instance.runtime_task_id == 0 or instance.task_kind != .builtin_session or instance.stop_requested) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var bytes: [32]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("running.stop-id"), &bytes, bytes.len, &needed) != abi.ok or needed == 0 or needed >= bytes.len) {
        instance.runtime_status = "请输入有效实例 ID";
        refresh(instance);
        return;
    }
    const id = std.fmt.parseInt(u64, bytes[0..needed], 10) catch 0;
    for (instance.running_rows.rows[0..instance.running_rows.count]) |item| {
        if (item.id != id or item.state == .stopping) continue;
        instance.runtime_status = if (instance.session.requestStop(id)) "已提交指定实例停止请求" else "停止请求繁忙；请稍后重试";
        refresh(instance);
        return;
    }
    instance.runtime_status = "实例 ID 不存在或已在退出";
    refresh(instance);
}

fn startLibraryAsset(instance: *Instance) void {
    if (!instance.library_loaded) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var bytes: [32]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("library.asset-id"), &bytes, bytes.len, &needed) != abi.ok or needed == 0 or needed >= bytes.len) {
        instance.library_status = "请输入有效素材 ID";
        refresh(instance);
        return;
    }
    const id = std.fmt.parseInt(u64, bytes[0..needed], 10) catch 0;
    if (id != 0 and id != library.builtin_asset_id) {
        for (instance.library_snapshot.rows[0..instance.library_snapshot.count]) |row| {
            if (row.id != id or !row.paired) continue;
            startAsset(instance, id);
            instance.section = .running;
            refresh(instance);
            return;
        }
    }
    instance.library_status = "素材不存在、未匹配或需要双摘要重验";
    refresh(instance);
}

fn startPreference(instance: *Instance, action_kind: library.PreferenceAction) void {
    if (instance.import_dialog != 0 or instance.import_request != null or instance.picker_request != 0 or instance.fallback_pick) return;
    if (!instance.active or !instance.library_loaded or instance.task_id != 0 or instance.runtime_task_id != 0 or config.runtime_sha256.len != 64 or instance.dispatch == null) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var id_bytes: [32]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("library.asset-id"), &id_bytes, id_bytes.len, &needed) != abi.ok or needed == 0 or needed >= id_bytes.len) {
        instance.library_status = "请输入有效素材 ID";
        refresh(instance);
        return;
    }
    const id = std.fmt.parseInt(u64, id_bytes[0..needed], 10) catch 0;
    for (instance.library_snapshot.rows[0..instance.library_snapshot.count]) |row| {
        if (row.id != id) continue;
        var edit: library.PreferenceEdit = .{ .row = row, .action = action_kind };
        if (action_kind != .toggle_favorite) {
            var tag: [65]u8 = undefined;
            needed = 0;
            if (get_state(panel.table.context, panel.id, abi.view("library.tag"), &tag, tag.len, &needed) != abi.ok or needed == 0 or needed > edit.tag.len or !std.unicode.utf8ValidateSlice(tag[0..needed])) {
                instance.library_status = "标签无效或超过 64 字节";
                refresh(instance);
                return;
            }
            @memcpy(edit.tag[0..needed], tag[0..needed]);
            edit.tag_len = needed;
        }
        instance.preference_edit = edit;
        startLibrary(instance, false);
        if (instance.task_id == 0) instance.preference_edit = null;
        refresh(instance);
        return;
    }
    instance.library_status = "素材不存在或不在当前筛选结果中";
    refresh(instance);
}

const Selection = struct {
    path: [4096]u8 = undefined,
    len: usize = 0,
    id: [64]u8 = undefined,
    id_len: usize = 0,

    fn fromPath(self: *Selection, path: []const u8) void {
        if (path.len < 4 or path.len > self.path.len or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\' or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return;
        @memcpy(self.path[0..path.len], path);
        self.len = path.len;
        const leaf = if (std.mem.lastIndexOfScalar(u8, path, '\\')) |last| path[last + 1 ..] else path;
        if (library.validSourceId(leaf)) {
            @memcpy(self.id[0..leaf.len], leaf);
            self.id_len = leaf.len;
        }
    }

    fn capture(user: ?*anyopaque, snapshot: [*c]const raw.PulseContextSelectionSnapshot) callconv(.c) void {
        const self: *Selection = @ptrCast(@alignCast(user orelse return));
        if (snapshot == null or snapshot[0].size < @sizeOf(raw.PulseContextSelectionSnapshot) or snapshot[0].entry_count != 1 or snapshot[0].entries == null) return;
        const entry = &snapshot[0].entries[0];
        if (entry.size < @sizeOf(raw.PulseContextSelectionEntry) or (entry.flags & raw.PULSE_CONTEXT_ENTRY_DIRECTORY) == 0) return;
        const path = abi.slice(entry.path) orelse return;
        if (path.len < 4 or path.len > self.path.len or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return;
        @memcpy(self.path[0..path.len], path);
        self.len = path.len;
        const name = abi.slice(entry.name) orelse return;
        if (library.validSourceId(name)) {
            @memcpy(self.id[0..name.len], name);
            self.id_len = name.len;
        }
    }
};

fn importClosed(user: ?*anyopaque, dialog: u64, status: abi.Status, button: abi.StringView, states: [*c]const ui.State, count: u32) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (dialog == 0 or dialog != instance.import_dialog) return;
    if (instance.dialog_command_subscription != 0) {
        const subscription = instance.dialog_command_subscription;
        instance.dialog_command_subscription = 0;
        if (instance.dialog_v2_table) |table| {
            if (table.unsubscribe_command) |unsubscribe| {
                const result = unsubscribe(table.context, subscription);
                if (result != abi.ok and result != abi.error_state) diag.status("companion-dialog-unsubscribe", result);
            }
        }
    }
    instance.import_dialog = 0;
    if (!instance.active) return;
    if (status != abi.ok or !std.mem.eql(u8, abi.slice(button) orelse "", "import")) {
        refresh(instance);
        return;
    }
    if (instance.task_id != 0 or instance.runtime_task_id != 0 or instance.section != .library or count != 2 or states == null) {
        instance.library_status = "导入条件已变化，请重试";
        refresh(instance);
        return;
    }
    var path: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    for (states[0..count]) |state| {
        const key = abi.slice(state.key) orelse continue;
        if (std.mem.eql(u8, key, "import.path") and path == null) path = abi.slice(state.value) else if (std.mem.eql(u8, key, "import.id") and id == null) id = abi.slice(state.value);
    }
    instance.import_request = library.ImportRequest.init(path orelse "", id orelse "") catch {
        instance.library_status = "请输入本地绝对目录及 pet.json 中的有效素材 ID";
        refresh(instance);
        return;
    };
    instance.import_result = null;
    instance.import_cancel_requested = false;
    startLibrary(instance, false);
    if (instance.task_id == 0) instance.import_request = null;
    refresh(instance);
}

fn showImport(instance: *Instance) void {
    if (!instance.active or instance.task_id != 0 or instance.runtime_task_id != 0 or instance.import_dialog != 0 or instance.tasks == null or instance.dispatch == null or config.helper_sha256.len != 64 or config.runtime_sha256.len != 64) return;
    if (instance.picker_request != 0 or instance.fallback_pick) return;
    var selection: Selection = .{};
    const context = instance.host.queryOptional(raw.PulseContextV1, raw.PULSE_CONTEXT_INTERFACE_NAME, raw.PULSE_CONTEXT_VERSION_1) catch null;
    if (context) |table| {
        if (table.get_selection) |get| {
            if (get(table.context, Selection.capture, &selection) != abi.ok) selection = .{};
        }
    }
    showImportWithSelection(instance, &selection);
}

fn pickerCompleted(user: ?*anyopaque, result: [*c]const pickers.Result) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (result == null or result[0].size < @sizeOf(pickers.Result) or result[0].request_id != instance.picker_request or instance.picker_request == 0) return;
    instance.picker_request = 0;
    instance.picker = null;
    const for_dialog = instance.picker_for_dialog;
    instance.picker_for_dialog = false;
    if (!instance.active or instance.section != .library) return;
    if (result[0].outcome == pickers.cancelled) {
        instance.library_status = if (for_dialog) "已取消选择；导入表单保持不变" else "已取消文件夹选择";
        refresh(instance);
        return;
    }
    if (result[0].outcome != pickers.accepted or result[0].path_count != 1 or result[0].paths == null) {
        instance.library_status = "Pulse 文件夹选择未成功；请手动填写";
        refresh(instance);
        return;
    }
    var selection: Selection = .{};
    selection.fromPath(abi.slice(result[0].paths[0]) orelse "");
    if (selection.len == 0) {
        instance.library_status = "仅支持本地绝对目录；请重新选择";
        refresh(instance);
        return;
    }
    if (for_dialog) {
        if (instance.import_dialog == 0) return;
        const table = instance.dialog_v2_table orelse {
            instance.library_status = "导入窗口已不支持更新；请重新打开";
            refresh(instance);
            return;
        };
        const set_states = table.set_states orelse return;
        const states = [_]ui.State{
            .{ .key = abi.view("import.path"), .value = abi.view(selection.path[0..selection.len]) },
            .{ .key = abi.view("import.id"), .value = abi.view(selection.id[0..selection.id_len]) },
        };
        const status = set_states(table.context, instance.import_dialog, &states, states.len);
        if (status == abi.ok) {
            instance.library_status = "已填入所选目录；请确认素材 ID 后导入";
        } else {
            diag.status("companion-dialog-set-picker-result", status);
            instance.library_status = "目录已选中，但表单更新失败；请手动填写";
        }
        refresh(instance);
        return;
    }
    showImportWithSelection(instance, &selection);
}

fn importDialogCommand(user: ?*anyopaque, dialog: u64, command: abi.StringView) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!instance.active or dialog == 0 or dialog != instance.import_dialog or instance.picker_request != 0 or !std.mem.eql(u8, abi.slice(command) orelse "", "browse")) return;
    const table = instance.picker_api orelse return;
    const pick = table.pick_folders orelse return;
    var request_id: u64 = 0;
    const request: pickers.Request = .{ .title = abi.view("选择桌宠素材文件夹"), .ok_label = abi.view("选择") };
    instance.picker_for_dialog = true;
    const status = pick(table.context, &request, pickerCompleted, instance, &request_id);
    if (status != abi.ok or request_id == 0) {
        instance.picker_for_dialog = false;
        diag.status("companion-dialog-folder-picker", status);
        instance.library_status = "宿主未能打开文件夹选择器；可手动填写路径";
        refresh(instance);
        return;
    }
    instance.picker = table;
    instance.picker_request = request_id;
    instance.library_status = "正在选择素材文件夹";
    refresh(instance);
}

fn browseImport(instance: *Instance) void {
    if (!instance.active or instance.task_id != 0 or instance.runtime_task_id != 0 or instance.import_dialog != 0 or instance.picker_request != 0 or instance.fallback_pick or instance.dialogs == null or instance.tasks == null or instance.dispatch == null or config.helper_sha256.len != 64 or config.runtime_sha256.len != 64) return;
    if (instance.picker_api) |picker| {
        if (picker.pick_folders) |pick| {
            if (picker.cancel != null) {
                const request: pickers.Request = .{ .title = abi.view("选择桌宠素材文件夹"), .ok_label = abi.view("选择") };
                var id: u64 = 0;
                const status = pick(picker.context, &request, pickerCompleted, instance, &id);
                if (status == abi.ok and id != 0) {
                    instance.picker = picker;
                    instance.picker_for_dialog = false;
                    instance.picker_request = id;
                    refresh(instance);
                    return;
                }
                if (status != abi.error_unavailable) {
                    instance.library_status = "宿主选择器未接受请求；请手动填写";
                    refresh(instance);
                    return;
                }
            }
        }
    }
    // Missing/unavailable host interface, not an explicit user cancel.
    instance.fallback_pick = true;
    instance.picked_folder = null;
    startLibrary(instance, false);
    if (instance.task_id == 0) {
        instance.fallback_pick = false;
        showImportWithSelection(instance, &.{});
    }
    refresh(instance);
}

fn showImportWithSelection(instance: *Instance, selection: *const Selection) void {
    if (!instance.active or instance.section != .library or instance.task_id != 0 or instance.runtime_task_id != 0 or instance.import_dialog != 0 or instance.picker_request != 0) return;
    const dialogs = instance.dialogs orelse return;
    const embedded_picker = instance.dialog_v2_table != null and instance.picker_api != null and !instance.dialog_picker_disabled;
    var fields = [_]ui.Node{ ui.node(ui.NodeKind.text_input), ui.node(ui.NodeKind.text_input), ui.node(ui.NodeKind.button) };
    fields[0].id = abi.view("import.path");
    fields[0].text = .{ .present = 1, .value = abi.view("素材文件夹") };
    fields[0].placeholder = .{ .present = 1, .value = abi.view("本地绝对路径，例如 C:\\Pets\\cat") };
    fields[0].state = .{ .present = 1, .value = abi.view("import.path") };
    fields[1].id = abi.view("import.id");
    fields[1].text = .{ .present = 1, .value = abi.view("来源 ID") };
    fields[1].placeholder = .{ .present = 1, .value = abi.view("pet.json 中的 id") };
    fields[1].state = .{ .present = 1, .value = abi.view("import.id") };
    var root = ui.node(ui.NodeKind.stack);
    root.id = abi.view("import.form");
    root.gap = .{ .present = 1, .value = 8 };
    if (embedded_picker) fields[2] = action("import.browse", "浏览文件夹…", "browse", instance.picker_request == 0);
    ui.withChildren(&root, fields[0..if (embedded_picker) @as(usize, 3) else 2]);
    const states = [_]ui.State{
        .{ .key = abi.view("import.path"), .value = abi.view(selection.path[0..selection.len]) },
        .{ .key = abi.view("import.id"), .value = abi.view(selection.id[0..selection.id_len]) },
    };
    var tree = std.mem.zeroes(ui.Tree);
    tree.size = @sizeOf(ui.Tree);
    tree.root = &root;
    tree.states = &states;
    tree.state_count = states.len;
    const dialog_commands = [_]abi.StringView{abi.view("browse")};
    if (embedded_picker) {
        tree.commands = &dialog_commands;
        tree.command_count = dialog_commands.len;
    }
    const buttons = [_]raw.PulseDialogButton{
        .{ .size = @sizeOf(raw.PulseDialogButton), .kind = raw.PULSE_DIALOG_BUTTON_PRIMARY, .id = abi.view("import"), .text = abi.view("导入") },
        .{ .size = @sizeOf(raw.PulseDialogButton), .kind = raw.PULSE_DIALOG_BUTTON_STANDARD, .id = abi.view("cancel"), .text = abi.view("取消") },
    };
    const request: raw.PulseDialogRequest = .{
        .size = @sizeOf(raw.PulseDialogRequest),
        .title = abi.view("导入 OpenPets 素材"),
        .message = abi.view("选择含 pet.json 的文件夹，确认来源 ID。仅复制到私有素材库，不修改源文件。"),
        .width = 560,
        .height = 160,
        .default_button = 0,
        .cancel_button = 1,
        .button_count = buttons.len,
        .buttons = &buttons,
        .model = &tree,
    };
    var id: u64 = 0;
    const show_status = if (embedded_picker) blk: {
        const table = instance.dialog_v2_table.?;
        const show = table.show orelse return;
        break :blk show(table.context, &request, null, importClosed, instance, &id);
    } else blk: {
        const show = dialogs.show orelse return;
        break :blk show(dialogs.context, &request, null, importClosed, instance, &id);
    };
    if (show_status != abi.ok or id == 0) {
        if (embedded_picker) {
            // If V2 rejects this model, retry with a V1-compatible form and
            // expose the separate toolbar picker instead of losing import.
            instance.dialog_picker_disabled = true;
            showImportWithSelection(instance, selection);
            return;
        }
        instance.library_status = "宿主未能打开导入确认窗口";
    } else {
        instance.import_dialog = id;
        if (embedded_picker) {
            const table = instance.dialog_v2_table.?;
            const subscribe = table.subscribe_command.?;
            var subscription: u64 = 0;
            const status = subscribe(table.context, id, abi.view("browse"), importDialogCommand, instance, &subscription);
            if (status == abi.ok and subscription != 0) {
                instance.dialog_command_subscription = subscription;
            } else {
                // Never leave a visible command without a live callback.
                instance.dialog_picker_disabled = true;
                if (table.close) |close_dialog| {
                    if (close_dialog(table.context, id) == abi.ok) {
                        showImportWithSelection(instance, selection);
                        return;
                    }
                }
                instance.library_status = "宿主不支持对话框内的选择命令；请手动填写";
            }
        }
    }
    refresh(instance);
}

fn cancelImport(instance: *Instance) void {
    if (instance.import_request == null or instance.task_id == 0 or instance.import_cancel_requested) return;
    const tasks = instance.tasks orelse return;
    const cancel = tasks.cancel orelse return;
    if (cancel(tasks.context, instance.task_id) == abi.ok) {
        instance.import_cancel_requested = true;
        instance.library_status = "已请求取消；等待受控 Helper 返回，已提交的写入不会撤销";
    } else {
        instance.library_status = "取消请求失败；仍保留任务所有权";
    }
    refresh(instance);
}

fn canMaintain(instance: *const Instance) bool {
    return instance.active and instance.library_loaded and instance.recovery_report != null and instance.tasks != null and instance.dispatch != null and instance.dialogs != null and instance.task_id == 0 and instance.runtime_task_id == 0 and instance.import_dialog == 0 and instance.removal_dialog == 0 and instance.removal_request == null and instance.picker_request == 0 and !instance.fallback_pick and !instance.recovery_scan and instance.preference_edit == null and instance.import_request == null;
}

fn confirmedRemoval(status: abi.Status, button: abi.StringView) bool {
    return status == abi.ok and std.mem.eql(u8, abi.slice(button) orelse "", "confirm");
}

fn removalClosed(user: ?*anyopaque, dialog: u64, status: abi.Status, button: abi.StringView, _: [*c]const ui.State, _: u32) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (dialog == 0 or dialog != instance.removal_dialog) return;
    instance.removal_dialog = 0;
    const request = instance.removal_request orelse return;
    instance.removal_request = null;
    if (!instance.active) return;
    if (!confirmedRemoval(status, button)) {
        instance.library_status = "已取消素材维护；未提交任务";
        refresh(instance);
        return;
    }
    if (instance.section != .library or !canMaintain(instance)) {
        instance.library_status = "素材维护条件已变化；请重新扫描";
        refresh(instance);
        return;
    }
    instance.removal_request = request;
    startLibrary(instance, false);
    if (instance.task_id == 0) instance.removal_request = null;
    refresh(instance);
}

fn showRemoval(instance: *Instance, action_kind: library.RemovalAction) void {
    if (config.runtime_sha256.len != 64 or !canMaintain(instance)) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var bytes: [32]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view(if (action_kind == .purge) "quarantine.id" else "library.asset-id"), &bytes, bytes.len, &needed) != abi.ok or needed == 0 or needed >= bytes.len) {
        instance.library_status = "请输入有效素材 ID";
        refresh(instance);
        return;
    }
    const id = std.fmt.parseInt(u64, bytes[0..needed], 10) catch 0;
    if (action_kind == .purge) {
        const report = &instance.recovery_report.?;
        for (report.quarantine[0..report.quarantine_count]) |*detail| {
            if (detail.id != id) continue;
            const request = library.RemovalRequest.initCleanup(detail) catch |err| {
                instance.library_status = @errorName(err);
                refresh(instance);
                return;
            };
            showRemovalDialog(instance, request);
            return;
        }
        instance.library_status = "隔离素材不在最近扫描结果中";
        refresh(instance);
        return;
    }
    for (instance.library_snapshot.rows[0..instance.library_snapshot.count]) |*row| {
        if (row.id != id) continue;
        const request = library.RemovalRequest.init(row, &instance.recovery_report.?, action_kind) catch |err| {
            instance.library_status = @errorName(err);
            refresh(instance);
            return;
        };
        showRemovalDialog(instance, request);
        return;
    }
    instance.library_status = "素材不存在或不在当前筛选结果中";
    refresh(instance);
}

fn showRemovalDialog(instance: *Instance, request: library.RemovalRequest) void {
    const dialogs = instance.dialogs orelse return;
    const show = dialogs.show orelse return;
    const removing = request.action == .quarantine;
    const purging = request.action == .purge;
    var message_buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, "素材 #{d}：{s}。{s}", .{ request.expected.id, request.expected.sourceId(), if (purging) "将永久删除已复验的受管隔离副本，不可撤销。原始导入目录和凭证不会删除；清理中断将禁止自动重试。" else if (removing) "将受管副本移入隔离区并从素材库移除；不会删除原始目录或隔离文件。" else "仅恢复仍登记的中断移除事务，不覆盖现有目录，不恢复已完成移除的 ID。" }) catch unreachable;
    var root = label("removal.notice", message);
    var tree = std.mem.zeroes(ui.Tree);
    tree.size = @sizeOf(ui.Tree);
    tree.root = &root;
    const buttons = [_]raw.PulseDialogButton{
        .{ .size = @sizeOf(raw.PulseDialogButton), .kind = raw.PULSE_DIALOG_BUTTON_PRIMARY, .id = abi.view("confirm"), .text = abi.view(if (purging) "永久清理" else if (removing) "隔离移除" else "恢复") },
        .{ .size = @sizeOf(raw.PulseDialogButton), .kind = raw.PULSE_DIALOG_BUTTON_STANDARD, .id = abi.view("cancel"), .text = abi.view("取消") },
    };
    const descriptor: raw.PulseDialogRequest = .{
        .size = @sizeOf(raw.PulseDialogRequest),
        .title = abi.view(if (purging) "确认永久清理（不可撤销）" else if (removing) "确认隔离移除" else "确认恢复中断移除"),
        .message = abi.view(message),
        .width = 560,
        .height = 160,
        .default_button = 1,
        .cancel_button = 1,
        .button_count = buttons.len,
        .buttons = &buttons,
        .model = &tree,
    };
    var dialog: u64 = 0;
    if (show(dialogs.context, &descriptor, null, removalClosed, instance, &dialog) == abi.ok and dialog != 0) {
        instance.removal_dialog = dialog;
        instance.removal_request = request;
    } else {
        instance.library_status = "宿主拒绝素材维护确认；未提交任务";
    }
    refresh(instance);
}

fn startRecovery(instance: *Instance) void {
    if (!instance.active or config.runtime_sha256.len != 64 or instance.dispatch == null or instance.tasks == null or instance.task_id != 0 or instance.runtime_task_id != 0 or instance.import_dialog != 0 or instance.picker_request != 0 or instance.fallback_pick or instance.preference_edit != null or instance.import_request != null) return;
    instance.recovery_report = null;
    instance.work_recovery_report = null;
    instance.recovery_scan = true;
    startLibrary(instance, false);
    if (instance.task_id == 0) instance.recovery_scan = false;
}

fn startLibrary(instance: *Instance, capture_query: bool) void {
    const tasks = instance.tasks orelse return;
    if (instance.task_id != 0 or instance.import_dialog != 0 or instance.removal_dialog != 0 or instance.picker_request != 0) return;
    const create = tasks.create orelse return;
    if (capture_query) {
        const panel = instance.panel orelse return;
        const get_state = panel.table.get_state orelse {
            instance.library_status = "宿主不支持读取搜索状态";
            refresh(instance);
            return;
        };
        var buffer: [257]u8 = undefined;
        var needed: u32 = 0;
        if (get_state(panel.table.context, panel.id, abi.view("library.query"), &buffer, buffer.len, &needed) != abi.ok or needed > instance.query.len or !validSearch(buffer[0..needed])) {
            instance.library_status = "搜索词无效或超过 256 字节";
            refresh(instance);
            return;
        }
        rememberSearch(instance, buffer[0..needed]);
        applySearch(instance);
    }
    instance.work_done.store(false, .release);
    instance.work_error = null;
    if (instance.import_request != null or instance.preference_edit != null or instance.removal_request != null) instance.recovery_report = null;
    instance.removal_committed = false;
    instance.work_snapshot = .{};
    if (!instance.fallback_pick and !instance.recovery_scan) instance.library_loaded = false;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view(if (instance.fallback_pick) "选择素材文件夹" else if (instance.recovery_scan) "扫描桌宠恢复状态" else if (instance.removal_request != null) "维护桌宠素材" else if (instance.import_request != null) "导入桌宠素材" else if (instance.preference_edit != null) "保存桌宠偏好" else "读取桌宠素材清单"),
        .type = abi.view("companion.library"),
        .work = readLibrary,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.task_id = id;
        instance.library_status = if (instance.fallback_pick) "正在使用 Windows 文件夹选择器（60 秒超时）" else if (instance.recovery_scan) "正在进行只读恢复扫描" else if (instance.removal_request != null) "正在维护桌宠素材" else if (instance.import_request != null) "正在导入本地素材" else if (instance.preference_edit != null) "正在保存素材偏好" else "正在自动读取素材清单";
        armTimer(instance);
        if (instance.timer == null) instance.library_status = "正在读取；宿主自动刷新不可用，可手动检查";
    } else {
        instance.library_status = "宿主拒绝读取任务";
    }
    refresh(instance);
}

fn onCommand(user: ?*anyopaque, panel: u64, command: abi.StringView) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!instance.active or panel != instance.page or instance.removal_dialog != 0) return;
    const name = abi.slice(command) orelse return;
    for (commands, 0..) |candidate, n| {
        if (!std.mem.eql(u8, candidate, name)) continue;
        if (n >= 4 and n <= 6 and instance.section != .global) return;
        if (n >= 7 and n <= 11 and instance.section != .library) return;
        if (n >= 12 and n <= 14 and instance.section != .running) return;
        if (n >= 15 and instance.section != .library) return;
        switch (n) {
            0, 1, 2, 3 => {
                instance.section = @fromBackingInt(@intCast(n));
                if ((instance.task_id != 0 or instance.runtime_task_id != 0) and instance.timer == null) pollTasks(instance);
                if (instance.section == .library) {
                    if (instance.search_pending) armTimer(instance);
                    if (!instance.library_loaded and instance.task_id == 0 and !instance.search_pending) startLibrary(instance, false);
                }
                if (instance.section == .running) startRuntimeCheck(instance);
                refresh(instance);
            },
            4 => load(instance),
            5 => if (instance.saved > 1) save(instance, instance.saved - 1),
            6 => if (instance.saved < 8) save(instance, instance.saved + 1),
            7 => startLibrary(instance, true),
            8 => pollTasks(instance),
            9 => if (instance.library_loaded and instance.library_offset >= 16) {
                instance.library_offset -= 16;
                refresh(instance);
            },
            11 => if (instance.task_id == 0 and instance.tasks != null) {
                instance.favorites_only = !instance.favorites_only;
                startLibrary(instance, true);
            },
            10 => if (instance.library_loaded and instance.library_offset + 16 < instance.library_snapshot.count) {
                instance.library_offset += 16;
                refresh(instance);
            },
            12 => startBuiltin(instance),
            13 => stopBuiltin(instance),
            14 => stopOne(instance),
            15 => startLibraryAsset(instance),
            16 => startPreference(instance, .toggle_favorite),
            17 => startPreference(instance, .add_tag),
            18 => startPreference(instance, .remove_tag),
            19 => showImport(instance),
            20 => cancelImport(instance),
            21 => browseImport(instance),
            22 => startRecovery(instance),
            23 => showRemoval(instance, .quarantine),
            24 => showRemoval(instance, .restore_interrupted),
            27 => showRemoval(instance, .purge),
            28 => clearSearch(instance),
            25 => if (instance.recovery_report != null and instance.quarantine_offset >= quarantine_page_size) {
                instance.quarantine_offset -= quarantine_page_size;
                refresh(instance);
            },
            26 => if (instance.recovery_report) |*report| {
                if (instance.quarantine_offset + quarantine_page_size < report.quarantine_count) {
                    instance.quarantine_offset += quarantine_page_size;
                    refresh(instance);
                }
            },
            else => {},
        }
        return;
    }
}

fn close(instance: *Instance) host_mod.Error!void {
    instance.active = false;
    instance.runtime_checked = false;
    instance.runtime_status = if (config.runtime_sha256.len == 0) "未打包运行时；无法启动桌宠" else "切换至运行管理时检查同包运行时";
    stopTimer(instance);
    instance.search_pending = false;
    instance.search_ticks = 0;
    if (instance.search_token != 0) {
        const events = instance.search_events orelse return error.State;
        const unsubscribe = events.unsubscribe orelse return error.Unavailable;
        host_mod.mapStatus(unsubscribe(events.context, instance.search_token)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.search_token = 0;
        instance.search_events = null;
        instance.search_revision = 0;
    }
    if (instance.picker_request != 0) {
        const picker = instance.picker orelse return error.State;
        const cancel = picker.cancel orelse return error.Unavailable;
        host_mod.mapStatus(cancel(picker.context, instance.picker_request)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.picker_request = 0;
        instance.picker = null;
    }
    if (instance.import_dialog != 0) {
        if (instance.dialog_command_subscription != 0) {
            const subscription = instance.dialog_command_subscription;
            instance.dialog_command_subscription = 0;
            if (instance.dialog_v2_table) |table| {
                const unsubscribe = table.unsubscribe_command orelse return error.Unavailable;
                const status = unsubscribe(table.context, subscription);
                if (status != abi.ok and status != abi.error_state) return error.State;
            }
        }
        const dialogs = instance.dialogs orelse return error.State;
        const close_status = if (instance.dialog_v2_table) |table| blk: {
            const close_dialog = table.close orelse return error.Unavailable;
            break :blk close_dialog(table.context, instance.import_dialog);
        } else blk: {
            const close_dialog = dialogs.close orelse return error.Unavailable;
            break :blk close_dialog(dialogs.context, instance.import_dialog);
        };
        host_mod.mapStatus(close_status) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.import_dialog = 0;
    }
    if (instance.removal_dialog != 0) {
        const dialogs = instance.dialogs orelse return error.State;
        const close_dialog = dialogs.close orelse return error.Unavailable;
        host_mod.mapStatus(close_dialog(dialogs.context, instance.removal_dialog)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.removal_dialog = 0;
        instance.removal_request = null;
    }
    instance.dialogs = null;
    instance.dialog_v2_table = null;
    instance.picker_api = null;
    instance.dialog_picker_disabled = false;
    instance.picker_for_dialog = false;
    var cancel_error: ?host_mod.Error = null;
    for ([_]u64{ instance.runtime_task_id, instance.task_id }) |id| {
        if (id == 0) continue;
        const tasks = instance.tasks orelse return error.State;
        const cancel = tasks.cancel orelse return error.Unavailable;
        host_mod.mapStatus(cancel(tasks.context, id)) catch |err| switch (err) {
            error.State => {},
            else => {
                cancel_error = err;
            },
        };
    }
    if (cancel_error) |err| return err;
    if (instance.pending != 0) {
        const resources = instance.resources orelse return error.State;
        const cancel = resources.cancel_request orelse return error.Unavailable;
        host_mod.mapStatus(cancel(resources.context, instance.pending)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.pending = 0;
        instance.pending_operation = 0;
    }
    if (instance.page != 0) {
        if (instance.pages) |pages| {
            const remove = pages.remove orelse return error.Unavailable;
            host_mod.mapStatus(remove(pages.context, instance.page)) catch |err| switch (err) {
                error.State => {},
                else => return err,
            };
        } else if (instance.panel) |*panel| {
            try panel.close();
        }
    }
    instance.page = 0;
    instance.panel = null;
    instance.pages = null;
    instance.subscriptions = @splat(0);
    instance.resources = null;
    instance.loaded = false;
}

fn open(instance: *Instance) host_mod.Error!void {
    if (instance.page != 0) return error.State;
    instance.dialog_picker_disabled = false;
    instance.dialogs = try instance.host.queryOptional(raw.PulseDialogsV1, raw.PULSE_DIALOGS_INTERFACE_NAME, raw.PULSE_DIALOGS_VERSION_1);
    if (instance.dialogs) |table| {
        if (table.show == null or table.close == null) instance.dialogs = null;
    }
    instance.dialog_v2_table = try instance.host.queryOptional(dialogs_v2.Table, dialogs_v2.name, dialogs_v2.version);
    if (instance.dialog_v2_table) |table| {
        if (table.show == null or table.set_states == null or table.close == null or table.subscribe_command == null or table.unsubscribe_command == null) instance.dialog_v2_table = null;
    }
    instance.picker_api = try instance.host.queryOptional(pickers.Table, pickers.name, pickers.version);
    if (instance.picker_api) |table| {
        if (table.pick_folders == null or table.cancel == null) instance.picker_api = null;
    }
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    instance.pages = try instance.host.queryOptional(raw.PulseSettingsPagesV1, raw.PULSE_SETTINGS_PAGES_INTERFACE_NAME, raw.PULSE_SETTINGS_PAGES_VERSION_1);
    errdefer close(instance) catch |err| diag.status("companion-open-cleanup", @intFromError(err));
    if (instance.pages) |pages| {
        const create = pages.create orelse return error.Unavailable;
        const query = pages.query orelse return error.Unavailable;
        _ = pages.remove orelse return error.Unavailable;
        try host_mod.mapStatus(create(pages.context, abi.view(title), &tree, &instance.page));
        if (instance.page == 0) return error.State;
        var table = std.mem.zeroes(ui.TableV1);
        try host_mod.mapStatus(query(pages.context, instance.page, abi.view(ui.interface_name), ui.version_1, &table, @sizeOf(ui.TableV1)));
        if (table.size < @sizeOf(ui.TableV1) or table.version < ui.version_1) return error.Abi;
        instance.panel = .{ .table = table, .id = instance.page };
    } else {
        instance.panel = try ui.Panel.open(instance.host, title, &tree);
        instance.page = instance.panel.?.id;
        if (mount.Mount.init(instance.host)) |placement| {
            placement.request(instance.page, .workspace) catch |err| diag.status("companion-mount-refused", @intFromError(err));
        } else |err| diag.status("companion-mount-unavailable", @intFromError(err));
    }
    if (instance.panel) |*panel| {
        if (panel.table.update == null or panel.table.subscribe_command == null or (instance.pages == null and panel.table.close == null)) return error.Unavailable;
        for (commands, 0..) |command, n| instance.subscriptions[n] = try panel.subscribeCommand(command, onCommand, instance);
    }
    instance.resources = try instance.host.queryOptional(raw.PulseResourcesV1, raw.PULSE_RESOURCES_INTERFACE_NAME, raw.PULSE_RESOURCES_VERSION_1);
    if (instance.resources) |resources| {
        if (resources.settings_get == null or resources.settings_set == null or resources.cancel_request == null) instance.resources = null;
    }
    if (instance.task_id == 0 and instance.runtime_task_id == 0) {
        instance.library_loaded = false;
        instance.library_offset = 0;
        instance.tasks = try instance.host.queryOptional(raw.PulseTasksV1, raw.PULSE_TASKS_INTERFACE_NAME, raw.PULSE_TASKS_VERSION_1);
        if (instance.tasks) |tasks| {
            if (tasks.create == null or tasks.get == null or tasks.release == null or tasks.cancel == null) instance.tasks = null;
        }
        instance.library_status = if (instance.tasks != null) "准备读取本地素材清单" else "宿主后台任务接口不可用";
    }
    instance.dispatch = try instance.host.queryOptional(raw.PulseDispatchV1, raw.PULSE_DISPATCH_INTERFACE, raw.PULSE_DISPATCH_VERSION);
    if (instance.dispatch) |dispatch| {
        if (dispatch.post == null or dispatch.cancel == null) instance.dispatch = null;
    }
    if (instance.dispatch != null and instance.tasks != null) subscribeSearch(instance);
    instance.active = true;
    const had_tasks = instance.task_id != 0 or instance.runtime_task_id != 0;
    if (had_tasks) {
        pollTasks(instance);
        if (instance.task_id != 0 or instance.runtime_task_id != 0) armTimer(instance);
    } else if (instance.section == .library) {
        startLibrary(instance, false);
    } else if (instance.section == .running) {
        startRuntimeCheck(instance);
    }
    if (instance.resources != null) {
        load(instance);
    } else {
        instance.status = "宿主设置接口不可用";
        refresh(instance);
    }
}

fn activate(user: ?*anyopaque) callconv(.c) abi.Status {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return abi.error_argument));
    open(instance) catch |err| {
        diag.status("companion-activate-failed", @intFromError(err));
        return abi.error_initialization;
    };
    diag.event("companion-activate");
    return abi.ok;
}

fn deactivate(user: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    close(instance) catch |err| {
        diag.status("companion-deactivate-failed", @intFromError(err));
        return;
    };
    diag.event("companion-deactivate");
}

fn destroy(user: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    close(instance) catch |err| {
        diag.status("companion-destroy-failed", @intFromError(err));
        return;
    };
    // The pinned host keeps the DLL and task userdata alive through stop;
    // destroy is called only after host task workers/cancel callbacks return.
    diag.event("companion-destroy");
    allocator.destroy(instance);
}

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1) or host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const validated = host_mod.Host.init(host) catch return abi.error_unavailable;
    diag.event("companion-entry");
    const instance = allocator.create(Instance) catch return abi.error_initialization;
    instance.* = .{ .host = validated };
    out.* = .{ .size = @sizeOf(abi.PluginV1), .version = abi.abi_version, .instance = instance, .activate = activate, .deactivate = deactivate, .destroy = destroy };
    return abi.ok;
}

test "settings preference validates exact value and duplicate keys" {
    var values = [_]raw.PulseSetting{ .{ .key = abi.view(preference), .value = abi.view("8") }, .{ .key = abi.view(preference), .value = abi.view("3") } };
    try std.testing.expectEqual(@as(u8, 4), try readPreference(.{}));
    try std.testing.expectEqual(@as(u8, 8), try readPreference(.{ .values = &values, .count = 1 }));
    try std.testing.expectError(error.InvalidSettings, readPreference(.{ .values = &values, .count = 2 }));
    values[0].value = abi.view("9");
    try std.testing.expectError(error.InvalidSettings, readPreference(.{ .values = &values, .count = 1 }));
}

test "four section tree declares only real navigation and preference actions" {
    var instance: Instance = .{ .host = undefined };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    for (0..names.len) |n| {
        instance.section = @fromBackingInt(@intCast(n));
        fill(&instance, &content, &tree);
        try std.testing.expectEqual(@as(u32, commands.len), tree.command_count);
        try std.testing.expectEqual(@as(u32, 4), content.children[0].children.count);
        try std.testing.expectEqualStrings(commands[n][10..], abi.slice(content.children[1].id).?);
        const expected: u32 = switch (instance.section) {
            .global, .library => 5,
            .running => 4,
            .market => 3,
        };
        try std.testing.expectEqual(expected, content.root.children.count);
    }
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[2].enabled.value);
}

test "running view exposes bounded start and stop actions" {
    var instance: Instance = .{ .host = undefined, .section = .running };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 4), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 2), content.children[3].children.count);
    try std.testing.expectEqualStrings(commands[12], abi.slice(content.toolbar[0].command.value).?);
    try std.testing.expectEqualStrings(commands[13], abi.slice(content.toolbar[1].command.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[0].enabled.value);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[1].enabled.value);
    instance.runtime_task_id = 1;
    instance.task_kind = .builtin_session;
    instance.session.set(.running);
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 5), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[0].enabled.value);
    try std.testing.expectEqual(@as(u32, 1), content.toolbar[1].enabled.value);
    instance.stop_requested = true;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[1].enabled.value);
    instance.section = .library;
    instance.tasks = std.mem.zeroes(raw.PulseTasksV1);
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 1), content.toolbar[1].enabled.value);
    instance.task_id = 2;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[1].enabled.value);
    try std.testing.expectEqual(@as(u64, 1), instance.runtime_task_id);
}

test "library view bounds rows and uses stable IDs" {
    var instance: Instance = .{ .host = undefined };
    instance.library_loaded = true;
    instance.library_snapshot.count = 17;
    for (instance.library_snapshot.rows[0..17], 0..) |*row, n| {
        row.* = .{ .id = n + 1, .source = @splat('a'), .len = 1, .paired = true };
    }
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 23), content.root.children.count);
    try std.testing.expect(std.mem.startsWith(u8, abi.slice(content.children[7].id).?, "asset-1-"));
    instance.library_offset = 16;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 8), content.root.children.count);
    try std.testing.expect(std.mem.startsWith(u8, abi.slice(content.children[7].id).?, "asset-11-"));
}

test "dynamic labels replace identity only when text changes" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const first = changingLabel(&a, "status", "old");
    const second = changingLabel(&b, "status", "new");
    try std.testing.expect(!std.mem.eql(u8, abi.slice(first.id).?, abi.slice(second.id).?));
    const again = changingLabel(&b, "status", "old");
    try std.testing.expectEqualStrings(abi.slice(first.id).?, abi.slice(again.id).?);
}

test "empty library hides pagination and manual poll unless needed" {
    var instance: Instance = .{ .host = undefined, .library_loaded = true };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 7), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 3), content.children[4].children.count);
    try std.testing.expectEqualStrings("library.empty", abi.slice(content.children[6].id).?);
    instance.library_snapshot.total = 1;
    fill(&instance, &content, &tree);
    try std.testing.expectEqualStrings("library.no-match", abi.slice(content.children[6].id).?);
    instance.task_id = 1;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 4), content.children[4].children.count);
}

test "recovery summary reports anomalies without promising repair" {
    var buffer: [1024]u8 = undefined;
    const body = try recoveryText(.{ .registered = 2, .missing = 1, .orphan_packages = 3, .invalid = 4, .quarantine_removed_bytes = 1024, .quarantine_unmeasured = 1 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, body, "未登记 1024 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "未统计目录 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "已登记 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "缺失 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "孤立目录 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "无效项 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "未执行清理") != null);
}

test "recovery labels identify registered assets and leave unknown IDs unmarked" {
    var snapshot: library.RecoverySnapshot = .{};
    snapshot.details[0] = .{ .id = 2, .state = .interrupted_removal };
    snapshot.details[1] = .{ .id = 3, .state = .missing };
    snapshot.count = 2;
    try std.testing.expectEqualStrings(" · 扫描：隔离待恢复", recoverySuffix(&snapshot, 2));
    try std.testing.expectEqualStrings(" · 扫描：目录缺失", recoverySuffix(&snapshot, 3));
    try std.testing.expectEqualStrings("", recoverySuffix(&snapshot, 4));
}

test "removal confirmation is explicit and cancellation clears copied request" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .active = true, .removal_dialog = 7 };
    instance.removal_request = .{ .expected = .{ .id = 1, .len = 3, .source = @splat(0) }, .action = .quarantine };
    try std.testing.expect(confirmedRemoval(abi.ok, abi.view("confirm")));
    try std.testing.expect(!confirmedRemoval(abi.ok, abi.view("cancel")));
    try std.testing.expect(!confirmedRemoval(abi.error_state, abi.view("confirm")));
    removalClosed(instance, 6, abi.ok, abi.view("confirm"), null, 0);
    try std.testing.expectEqual(@as(u64, 7), instance.removal_dialog);
    removalClosed(instance, 7, abi.ok, abi.view("cancel"), null, 0);
    try std.testing.expectEqual(@as(u64, 0), instance.removal_dialog);
    try std.testing.expect(instance.removal_request == null);
    try std.testing.expectEqual(@as(u64, 0), instance.task_id);
    try std.testing.expect(!canMaintain(instance));
}

test "import toolbar initializes every visible node for both picker modes" {
    var nodes: [3]ui.Node = undefined;
    for ([_]bool{ false, true }) |embedded| {
        const idle = fillImportToolbar(&nodes, embedded, true, false, false);
        try std.testing.expectEqual(@as(usize, if (embedded) 1 else 2), idle.len);
        try std.testing.expectEqualStrings(commands[19], abi.slice(idle[0].command.value).?);
        if (!embedded) try std.testing.expectEqualStrings(commands[21], abi.slice(idle[1].command.value).?);
        const busy = fillImportToolbar(&nodes, embedded, false, true, true);
        try std.testing.expectEqual(@as(usize, if (embedded) 2 else 3), busy.len);
        try std.testing.expectEqualStrings(commands[19], abi.slice(busy[0].command.value).?);
        if (!embedded) try std.testing.expectEqualStrings(commands[21], abi.slice(busy[1].command.value).?);
        try std.testing.expectEqualStrings(commands[20], abi.slice(busy[busy.len - 1].command.value).?);
        try std.testing.expectEqual(@as(u32, 1), busy[busy.len - 1].enabled.value);
        const canceling = fillImportToolbar(&nodes, embedded, false, true, false);
        try std.testing.expectEqual(@as(u32, 0), canceling[canceling.len - 1].enabled.value);
    }
}

test "quarantine rows distinguish unknown size from measured zero" {
    var buffer: [160]u8 = undefined;
    const detail: library.QuarantineDetail = .{ .id = 7, .state = .unregistered_retained };
    const unknown = try quarantineText(detail, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "大小未统计") != null);
    var measured = detail;
    measured.logical_bytes = 0;
    const zero = try quarantineText(measured, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, zero, "0 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, zero, "来源未证实") != null);
}

test "search field uses a native placeholder and separate controls" {
    var instance: Instance = .{ .host = undefined };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(&instance, &content, &tree);
    try std.testing.expectEqual(ui.NodeKind.text_input, content.children[3].type);
    try std.testing.expectEqualStrings("library.query", abi.slice(content.children[3].state.value).?);
    try std.testing.expectEqualStrings("search", abi.slice(content.children[3].glyph.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.children[3].text.present);
    try std.testing.expectEqualStrings(commands[7], abi.slice(content.toolbar[0].command.value).?);
    try std.testing.expectEqualStrings(commands[28], abi.slice(content.toolbar[2].command.value).?);
}

test "typing copies latest user query without mutating the worker input" {
    var instance: Instance = .{ .host = undefined, .active = true, .page = 9, .search_token = 1, .task_id = 12 };
    rememberSearch(&instance, "old");
    applySearch(&instance);
    var change: raw.PulseUiStateChange = .{ .key = abi.view("library.query"), .value = abi.view("猫"), .revision = 2, .source_mask = @intCast(raw.PULSE_UI_STATE_USER) };
    var batch: raw.PulseUiStateBatch = .{ .revision = 2, .changes = &change, .count = 1 };
    onSearchChanged(&instance, 9, &batch);
    try std.testing.expectEqualStrings("猫", instance.search_draft[0..instance.search_draft_len]);
    try std.testing.expectEqualStrings("old", instance.query[0..instance.query_len]);
    change.value = abi.view("wrong");
    change.revision = 3;
    change.source_mask = @intCast(raw.PULSE_UI_STATE_PROGRAMMATIC);
    onSearchChanged(&instance, 9, &batch);
    try std.testing.expectEqualStrings("猫", instance.search_draft[0..instance.search_draft_len]);
    instance.task_id = 0;
    applySearch(&instance);
    try std.testing.expectEqualStrings("猫", instance.query[0..instance.query_len]);
    try std.testing.expect(!validSearch("a\x00b"));
}
