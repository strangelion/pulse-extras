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
const runtime_preference = "runtime.limits";
const running_page_size: usize = 12;
const Section = enum { library, running, market, global };
const TaskKind = enum { runtime_check, builtin_session };
const names = [_][]const u8{ "素材库", "运行管理", "在线市场", "全局设置" };
const commands = [_][]const u8{ "companion.library", "companion.running", "companion.market", "companion.global", "companion.settings.refresh", "companion.download.less", "companion.download.more", "companion.library.reload", "companion.library.poll", "companion.library.previous", "companion.library.next", "companion.library.favorites", "companion.running.start", "companion.running.stop", "companion.running.stop-one", "companion.library.start", "companion.library.favorite-toggle", "companion.library.tag-add", "companion.library.tag-remove", "companion.library.import", "companion.library.import-cancel", "companion.library.browse", "companion.library.recovery-scan", "companion.library.remove", "companion.library.restore", "companion.quarantine.previous", "companion.quarantine.next", "companion.quarantine.purge", "companion.library.search-clear", "companion.running.search", "companion.running.search-clear", "companion.market.search", "companion.market.offline", "companion.market.previous", "companion.market.next", "companion.market.install-base", "companion.market.install-full", "companion.market.cancel", "companion.market.poll", "companion.market.search-clear", "companion.market.select-1", "companion.market.select-2", "companion.market.select-3", "companion.market.select-4", "companion.market.select-5", "companion.market.select-6", "companion.market.select-7", "companion.market.select-8", "companion.market.select-9", "companion.market.select-10", "companion.market.select-11", "companion.market.select-12", "companion.runtime.limits-save", "companion.running.previous", "companion.running.next", "companion.market.filter-mode", "companion.market.filter-category", "companion.market.filter-version", "companion.market.queue-base", "companion.market.queue-full", "companion.market.queue-start", "companion.market.queue-clear", "companion.market.queue-item-1", "companion.market.queue-item-2", "companion.market.queue-item-3", "companion.market.queue-item-4", "companion.market.queue-item-5", "companion.market.queue-item-6", "companion.market.queue-item-7", "companion.market.queue-item-8", "companion.library.profile-default", "companion.library.profile-alternate", "companion.library.profile-reset", "companion.library.profile-clear", "companion.library.start-alternate", "companion.library.start-custom", "companion.library.detail", "companion.market.image-test", "companion.market.open-gallery", "companion.market.image-fallback", "companion.runtime.policy-save", "companion.runtime.plan-start", "companion.runtime.plan-cancel", "companion.running.hide", "companion.running.show", "companion.running.hide-all", "companion.running.show-all", "companion.runtime.diagnostics" };

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
    runtime_limits: library.RuntimeLimits = .{},
    runtime_policy: library.RuntimePolicy = .{},
    policy_write_pending: bool = false,
    policy_sync_failed: bool = false,
    auto_considered: bool = false,
    auto_pending: bool = false,
    diagnostic_pending: bool = false,
    diagnostic_history_allowed: bool = false,
    diagnostic_report: [4096]u8 = undefined,
    diagnostic_report_len: usize = 0,
    diagnostic_path: [1024]u8 = undefined,
    diagnostic_path_len: usize = 0,
    diagnostic_status: []const u8 = "尚未导出诊断",
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
    detail_request: ?library.AssetDetailRequest = null,
    detail_work: ?library.AssetDetail = null,
    library_detail: ?struct { id: u64, detail: library.AssetDetail } = null,
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
    market_request: ?library.MarketRequest = null,
    market_query: library.MarketSearch = .{},
    market_snapshot: library.MarketSnapshot = .{},
    market_selected: ?usize = null,
    market_filters: library.MarketFilters = .{},
    market_detail: ?library.MarketDetail = null,
    // Session-only diagnostic. Never submit unknown remote content to the host.
    market_image_test: bool = false,
    market_browser_pending: bool = false,
    market_image_rejected: bool = false,
    market_outcome: library.MarketOutcome = .{},
    market_progress: library.MarketProgress = .{},
    market_queue: library.MarketBatch = .{},
    market_queue_done: bool = false,
    market_queue_cleanup: bool = false,
    market_status: []const u8 = "OpenPets 市场：主动搜索后才联网",
    market_cancel_requested: bool = false,
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
    running_search_token: u64 = 0,
    running_search_revision: u64 = 0,
    running_query: [256]u8 = undefined,
    running_query_len: usize = 0,
    running_offset: usize = 0,
    favorites_only: bool = false,
    status: []const u8 = "设置尚未读取",
};

const Content = struct {
    declared: [commands.len]abi.StringView = undefined,
    navigation: [4]ui.Node = undefined,
    // Maximum market view includes the preview diagnostic, manual task
    // collection, queue, 12 results and selected detail simultaneously.
    children: [36]ui.Node = undefined,
    removal_toolbar: [2]ui.Node = undefined,
    import_toolbar: [3]ui.Node = undefined,
    toolbar: [4]ui.Node = undefined,
    paging: [2]ui.Node = undefined,
    states: [26]ui.State = undefined,
    policy_fields: [15][64]u8 = undefined,
    policy_nodes: [17]ui.Node = undefined,
    policy_numeric: [4]ui.Node = undefined,
    policy_text: [512]u8 = undefined,
    policy_actions: [3]ui.Node = undefined,
    visibility_actions: [4]ui.Node = undefined,
    plan_status: [192]u8 = undefined,
    plan_status_id: [64]u8 = undefined,
    diagnostic_text: [1024]u8 = undefined,
    diagnostic_id: [64]u8 = undefined,
    profile_controls: [4]ui.Node = undefined,
    profile_launch: [2]ui.Node = undefined,
    profile_group: [5]ui.Node = undefined,
    local_detail_nodes: [4]ui.Node = undefined,
    local_detail_title: [448]u8 = undefined,
    local_detail_info: [224]u8 = undefined,
    local_detail_ids: [3][64]u8 = undefined,
    profile_line: [16][96]u8 = undefined,
    market_actions: [5]ui.Node = undefined,
    market_paging: [2]ui.Node = undefined,
    market_install: [4]ui.Node = undefined,
    market_queue_nodes: [11]ui.Node = undefined,
    market_queue_text: [8][768]u8 = undefined,
    market_queue_ids: [8][64]u8 = undefined,
    market_queue_toolbar: [2]ui.Node = undefined,
    market_queue_summary: [128]u8 = undefined,
    market_queue_summary_id: [64]u8 = undefined,
    market_filter_actions: [3]ui.Node = undefined,
    market_detail_text: [640]u8 = undefined,
    market_detail_id: [64]u8 = undefined,
    market_description_id: [64]u8 = undefined,
    market_rows: [12][576]u8 = undefined,
    market_row_ids: [12][64]u8 = undefined,
    market_info: [256]u8 = undefined,
    market_transfer: [128]u8 = undefined,
    market_transfer_id: [64]u8 = undefined,
    market_selection_text: [640]u8 = undefined,
    market_selection_id: [64]u8 = undefined,
    preference_toolbar: [4]ui.Node = undefined,
    asset_toolbar: [2]ui.Node = undefined,
    stop_toolbar: [2]ui.Node = undefined,
    row_text: [16][640]u8 = undefined,
    row_ids: [16][64]u8 = undefined,
    dynamic_ids: [4][64]u8 = undefined,
    library_count: [160]u8 = undefined,
    recovery_text: [1024]u8 = undefined,
    quarantine_nodes: [7]ui.Node = undefined,
    cleanup_toolbar: [2]ui.Node = undefined,
    quarantine_paging: [2]ui.Node = undefined,
    running_count: [96]u8 = undefined,
    running_count_id: [64]u8 = undefined,
    running_search_toolbar: [2]ui.Node = undefined,
    running_paging: [2]ui.Node = undefined,
    limits_inputs: [2]ui.Node = undefined,
    limits_count: [16]u8 = undefined,
    limits_memory: [16]u8 = undefined,
    limits_text: [320]u8 = undefined,
    limits_id: [64]u8 = undefined,
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
    return std.fmt.bufPrint(buffer, "最近一次只读扫描：已登记 {d} · 缺失 {d} · 孤立目录 {d} · 待处理目录 {d} · 待处理记录 {d} · 孤立偏好 {d} · 无效项 {d} · 未知项 {d} · 未预留 ID {d} · 隔离待恢复 {d} · 未登记保留 {d}。隔离逻辑字节：待恢复 {d} B · 未登记 {d} B · 未统计目录 {d}。凭证 {d} · 待处理凭证 {d} · 清理标记 {d} · 待处理清理 {d} · 诊断历史待处理 {d}。未验证文件内容，未执行清理。", .{ report.registered, report.missing, report.orphan_packages, report.pending_directories, report.pending_records, report.orphan_preferences, report.invalid, report.unknown, report.unreserved, report.quarantined_registered, report.quarantined_removed, report.quarantine_registered_bytes, report.quarantine_removed_bytes, report.quarantine_unmeasured, report.receipts, report.receipt_pending, report.cleanup_markers, report.cleanup_pending, report.history_pending });
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

fn searchInput(id: []const u8, prompt: []const u8) ui.Node {
    var node = ui.node(ui.NodeKind.text_input);
    node.id = abi.view(id);
    node.placeholder = .{ .present = 1, .value = abi.view(prompt) };
    node.glyph = .{ .present = 1, .value = abi.view("search") };
    node.state = .{ .present = 1, .value = abi.view(id) };
    node.flex = .{ .present = 1, .value = 1 };
    return node;
}

fn containsFolded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |n| {
        if (std.ascii.eqlIgnoreCase(haystack[n..][0..needle.len], needle)) return true;
    }
    return false;
}

fn runningMatches(item: library.RunningRow, source: []const u8, query: []const u8) bool {
    var terms = std.mem.tokenizeAny(u8, query, " \t");
    while (terms.next()) |term| {
        if (containsFolded(source, term)) continue;
        const numeric = if (std.mem.startsWith(u8, term, "#")) term[1..] else term;
        const id = std.fmt.parseInt(u64, numeric, 10) catch return false;
        if (item.id == id or item.asset_id == id) continue;
        if (item.metrics) |metrics| {
            if (metrics.pid != 0 and metrics.pid == id) continue;
        }
        return false;
    }
    return true;
}

fn runningMatchCount(instance: *const Instance) usize {
    var count: usize = 0;
    for (instance.running_rows.rows[0..instance.running_rows.count], 0..) |item, n| {
        if (runningMatches(item, instance.running_rows.sources[n].text(), instance.running_query[0..instance.running_query_len])) count += 1;
    }
    return count;
}

fn runningPageStart(offset: usize, total: usize) usize {
    if (total == 0) return 0;
    return @min(offset / running_page_size, (total - 1) / running_page_size) * running_page_size;
}

fn marketIdle(instance: *const Instance) bool {
    return instance.active and instance.section == .market and instance.task_id == 0 and instance.runtime_task_id == 0 and instance.tasks != null and instance.dispatch != null and instance.market_request == null and instance.import_dialog == 0 and instance.removal_dialog == 0 and instance.picker_request == 0 and instance.preference_edit == null and instance.import_request == null and instance.removal_request == null and !instance.recovery_scan and !instance.fallback_pick and config.runtime_sha256.len == 64 and config.helper_sha256.len == 64;
}

fn fillMarketQueue(instance: *const Instance, content: *Content) ui.Node {
    const batch_busy = if (instance.market_request) |request| request == .batch else false;
    const idle = marketIdle(instance);
    const count = instance.market_queue.count;
    const line = std.fmt.bufPrint(&content.market_queue_summary, "下载队列 {d}/8 · 并发 {d}{s}", .{ count, if (batch_busy or instance.market_queue_done) instance.market_queue.concurrency else instance.saved, if (instance.market_queue_cleanup) " · 清理未确认" else "" }) catch unreachable;
    content.market_queue_nodes[0] = changingLabel(&content.market_queue_summary_id, "market.queue.summary", line);
    for (instance.market_queue.selections[0..count], 0..) |*selected, n| {
        const progress = &instance.market_progress.jobs[n];
        const state: library.MarketJobState = if (batch_busy or instance.market_queue_done) progress.get() else .waiting;
        const status: []const u8 = switch (state) {
            .waiting => "等待",
            .downloading => "下载中",
            .installing => "校验并安装",
            .imported => "已安装",
            .existing => "已存在",
            .failed => "失败",
            .canceled => "已取消",
            .cleanup_required => "需要恢复",
        };
        const body = std.fmt.bufPrint(&content.market_queue_text[n], "{s} · {s} · {s} · {d}/{d} B{s}", .{ selected.hit.displayName(), if (selected.full) "完整包" else "基础包", status, if (batch_busy or instance.market_queue_done) progress.transfer.received.load(.acquire) else 0, if (batch_busy or instance.market_queue_done) progress.transfer.expected.load(.acquire) else 0, if (batch_busy) "（点击取消）" else if (!instance.market_queue_done) "（点击移除）" else "" }) catch unreachable;
        const id = std.fmt.bufPrint(&content.market_queue_ids[n], "queue-{d}-{x}", .{ n, std.hash.Wyhash.hash(0, body) }) catch unreachable;
        const cancelable = state == .waiting or state == .downloading or state == .installing;
        content.market_queue_nodes[n + 1] = action(id, body, commands[62 + n], (batch_busy and cancelable and !progress.canceled.load(.acquire)) or (idle and !instance.market_queue_done));
    }
    content.market_queue_toolbar[0] = action("market.queue-start", "开始队列", commands[60], idle and count != 0 and !instance.market_queue_done and instance.loaded);
    content.market_queue_toolbar[1] = action("market.queue-clear", "清空队列", commands[61], idle and count != 0);
    content.market_queue_nodes[count + 1] = horizontal("market.queue-actions", &content.market_queue_toolbar);
    var node = ui.node(ui.NodeKind.stack);
    node.id = abi.view("market.queue");
    node.gap = .{ .present = 1, .value = 4 };
    ui.withChildren(&node, content.market_queue_nodes[0 .. count + 2]);
    return node;
}

// Preview 3 (1.0.61, local reference 20261124) ui_model.h SHA-256:
// a07f8449a6cd6801877813d30c0b7a6a3755a659c0f0154e093540fde140e792
// The public pinned build has COUNT=41. The later SDK adds IMAGE=44
// without changing the node layout. Keep this opt-in adapter local until
// the newer SDK becomes the public baseline.
const preview3_image_type: u32 = 44;
const preview3_fixture = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAASElEQVR42mN88fkPAzUACwMDg37pAfyKrBzX4Fcw3WsKEwOVwKhBowYNKoNYGBgYsh8SyG75T0/hV/B9NLBHDRquBjFSqzoCAFBxDz4y6Mz0AAAAAElFTkSuQmCC";

comptime {
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(ui.Node) != 1296 or @alignOf(ui.Node) != 8 or
            @offsetOf(ui.Node, "type") != 4 or @offsetOf(ui.Node, "text") != 24 or
            @offsetOf(ui.Node, "glyph") != 168 or @offsetOf(ui.Node, "kind") != 768 or
            @offsetOf(ui.Node, "min_height") != 952 or @sizeOf(ui.TableV1) != 72)
            @compileError("Preview 3 image adapter ABI mismatch");
    }
}

// Matches ModelNode::Image in the verified SDK. Source syntax is a host
// acceptance question, not implied by this field mapping.
fn preview3Image(id: []const u8, source: []const u8, alt: []const u8) ui.Node {
    var node = ui.node(preview3_image_type);
    node.id = abi.view(id);
    node.glyph = .{ .present = 1, .value = abi.view(source) };
    node.kind = .{ .present = 1, .value = abi.view("contain") };
    node.text = .{ .present = 1, .value = abi.view(alt) };
    node.min_height = .{ .present = 1, .value = 64 };
    return node;
}

fn marketBrowserIdle(instance: *const Instance) bool {
    return instance.active and instance.section == .market and instance.task_id == 0 and instance.tasks != null and !instance.market_browser_pending and instance.import_dialog == 0 and instance.removal_dialog == 0 and instance.picker_request == 0;
}

fn fillMarket(instance: *const Instance, content: *Content) usize {
    const idle = marketIdle(instance);
    const busy = instance.market_request != null and instance.task_id != 0;
    content.children[2] = changingLabel(&content.dynamic_ids[0], "market.status", instance.market_status);
    content.children[3] = searchInput("market.query", "搜索精选、原创桌宠名称或来源 ID");
    content.children[3].enabled = .{ .present = 1, .value = @intFromBool(!busy) };
    content.market_actions[0] = action("market.search", "在线搜索", commands[31], idle);
    content.market_actions[1] = action("market.offline", "离线缓存", commands[32], idle);
    content.market_actions[2] = action("market.cancel", "取消任务", commands[37], busy and !instance.market_cancel_requested);
    const can_clear = if (instance.panel) |panel| panel.table.set_states != null else false;
    content.market_actions[3] = action("market.search-clear", "清空搜索", commands[39], !busy and can_clear);
    content.market_actions[4] = action("market.open-gallery", "浏览器查看图库 ↗", commands[78], marketBrowserIdle(instance));
    content.children[4] = horizontal("market.actions", &content.market_actions);
    content.children[5] = label("market.notice", "图片无法显示时可在浏览器查看官方图库：" ++ library.market_gallery_url ++ "。来源目录未提供明确许可时不得推定授权。");
    const filters = instance.market_filters;
    content.market_filter_actions[0] = action("market.filter-mode", switch (filters.mode) {
        .curated => "范围：精选或原创",
        .all => "范围：全部",
        .original => "范围：原创",
        .featured => "范围：精选",
        .exact_id => "范围：精确来源 ID",
    }, commands[55], idle);
    content.market_filter_actions[1] = action("market.filter-category", switch (filters.category) {
        .any => "类别：不限",
        .asian => "类别：亚洲",
        .western => "类别：欧美",
    }, commands[56], idle and filters.mode != .exact_id);
    content.market_filter_actions[2] = action("market.filter-version", switch (filters.version) {
        .any => "版本：不限",
        .v1 => "版本：V1",
        .v2 => "版本：V2",
    }, commands[57], idle and filters.mode != .exact_id);
    content.children[6] = horizontal("market.filters", &content.market_filter_actions);
    var count: usize = 7;
    content.children[count] = action("market.image-test", if (instance.market_image_rejected) "本次已回退文字显示" else if (instance.market_image_test) "关闭 SDK 图片测试" else "SDK 图片测试（不联网）", commands[77], !busy and !instance.market_image_rejected);
    count += 1;
    if (instance.market_image_test) {
        content.children[count] = preview3Image("market.image-fixture", preview3_fixture, "SDK 测试图：蓝绿紫橙四格");
        count += 1;
        content.children[count] = action("market.image-fallback", "图片不可见？本次回退文字显示", commands[79], true);
        count += 1;
    }
    if (instance.market_queue.count != 0) {
        content.children[count] = fillMarketQueue(instance, content);
        count += 1;
    }
    if (busy and instance.market_request.? != .batch) {
        const received = instance.market_progress.http_progress.received.load(.acquire);
        const expected = instance.market_progress.http_progress.expected.load(.acquire);
        const text = if (expected == 0) std.fmt.bufPrint(&content.market_transfer, "当前请求：{d} B（总量未知）", .{received}) catch unreachable else std.fmt.bufPrint(&content.market_transfer, "当前请求：{d} / {d} B", .{ received, expected }) catch unreachable;
        content.children[count] = changingLabel(&content.market_transfer_id, "market.transfer", text);
        count += 1;
    }
    // Also collect browser handoffs and batch jobs when the dispatcher or
    // timer is absent; unrelated library work can be collected here too.
    if (instance.task_id != 0 and instance.timer == null) {
        content.children[count] = action("market.poll", "手动检查任务状态", commands[38], true);
        count += 1;
    }
    if (instance.market_snapshot.result) |*result| {
        const snapshot = &instance.market_snapshot;
        const written = @min(result.summary.written, snapshot.rows.len);
        const info = std.fmt.bufPrint(&content.market_info, "结果 {d} 项 · 第 {d}–{d} 项 · {s}", .{ result.summary.total, if (written == 0) 0 else snapshot.query.offset + 1, snapshot.query.offset + written, if (snapshot.query.offline) "仅缓存，不能安装" else if (result.stale) "过期缓存，不能安装" else "安装时重新核对版本" }) catch unreachable;
        content.children[count] = changingLabel(&content.dynamic_ids[1], "market.summary", info);
        count += 1;
        for (snapshot.rows[0..written], 0..) |*row, n| {
            const selected = instance.market_selected != null and instance.market_selected.? == n;
            const body = std.fmt.bufPrint(&content.market_rows[n], "{s}{s} · {s}", .{ if (selected) "已选： " else "", row.displayName(), row.sourceId() }) catch unreachable;
            const id = std.fmt.bufPrint(&content.market_row_ids[n], "market-row-{d}-{x}", .{ n, std.hash.Wyhash.hash(0, body) }) catch unreachable;
            content.children[count] = action(id, body, commands[40 + n], idle);
            content.children[count].selected = .{ .present = 1, .value = @intFromBool(selected) };
            count += 1;
        }
        content.market_paging[0] = action("market.previous", "上一页", commands[33], idle and snapshot.query.offset >= snapshot.rows.len);
        content.market_paging[1] = action("market.next", "下一页", commands[34], idle and snapshot.query.offset + written < result.summary.total and written != 0);
        content.children[count] = horizontal("market.paging", &content.market_paging);
        count += 1;
        if (written != 0) {
            const choice = instance.market_selected;
            const selected = if (choice) |n| n < written else false;
            const description = if (selected) blk: {
                const row = &snapshot.rows[choice.?];
                break :blk std.fmt.bufPrint(&content.market_selection_text, "已选择：{s} · {s}", .{ row.displayName(), row.sourceId() }) catch unreachable;
            } else "点击上方素材查看详情";
            content.children[count] = changingLabel(&content.market_selection_id, "market.selection", description);
            count += 1;
            if (selected) {
                if (instance.market_detail) |*detail| {
                    const minimum = if (detail.minimum_len == 0) "未声明" else detail.minimum[0..detail.minimum_len];
                    const info_line = std.fmt.bufPrint(&content.market_detail_text, "{s} · V{d} · {s} · {s} · 最低 OpenPets 版本：{s} · {s} · {s}", .{ if (detail.category == .asian) "亚洲" else "欧美", detail.version, if (detail.original) "标记原创" else "未标记原创", if (detail.featured) "精选" else "非精选", minimum, if (detail.compatible) "格式初步兼容" else "暂不兼容", if (detail.stale) "过期详情" else if (!detail.installable) "仅查看" else "可申请安装" }) catch unreachable;
                    content.children[count] = changingLabel(&content.market_detail_id, "market.detail", info_line);
                    count += 1;
                    content.children[count] = changingLabel(&content.market_description_id, "market.description", detail.description[0..detail.description_len]);
                    count += 1;
                    content.children[count] = label("market.license", "作者与许可：当前协议未提供经过验证的字段，请自行确认。");
                    count += 1;
                    if (detail.subcategory_len != 0) {
                        content.children[count] = label("market.subcategory", detail.subcategory[0..detail.subcategory_len]);
                        count += 1;
                    }
                    const can_install = idle and !snapshot.query.offline and !result.stale and detail.installable;
                    content.market_install[0] = action("market.install-base", "下载并安装基础包", commands[35], can_install);
                    content.market_install[1] = action("market.install-full", if (detail.wardrobe) "下载并安装完整包" else "没有独立完整包", commands[36], can_install and detail.wardrobe);
                    content.market_install[2] = action("market.queue-base", "基础包加入队列", commands[58], can_install and !instance.market_queue_done and instance.market_queue.count < library.MarketQueueCapacity);
                    content.market_install[3] = action("market.queue-full", "完整包加入队列", commands[59], can_install and detail.wardrobe and !instance.market_queue_done and instance.market_queue.count < library.MarketQueueCapacity);
                    content.children[count] = horizontal("market.install", &content.market_install);
                    count += 1;
                } else {
                    content.children[count] = label("market.detail-pending", "详情尚未读取或读取失败；可重新选择该素材。");
                    count += 1;
                }
            }
        } else if (written == 0) {
            content.children[count] = label("market.no-match", "没有匹配的素材，请调整搜索词。");
            count += 1;
        }
    }
    return count;
}

fn profileText(profile: library.Profile, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}% · 置顶{s} · 低动态{s}", .{ profile.scale, if (profile.topmost) "开" else "关", if (profile.reduced) "开" else "关" }) catch unreachable;
}

fn fillProfileControls(content: *Content, edit_enabled: bool, launch_enabled: bool) ui.Node {
    content.profile_group[0] = label("library.profile.help", "选定素材 ID 后配置启动效果：缩放50–200:置顶0/1:低动态0/1。例如125:1:0。仅影响新启动的实例。");
    content.profile_group[1] = ui.node(ui.NodeKind.text_input);
    content.profile_group[1].id = abi.view("library.profile");
    content.profile_group[1].state = .{ .present = 1, .value = abi.view("library.profile") };
    content.profile_group[1].placeholder = .{ .present = 1, .value = abi.view("100:0:0") };
    content.profile_controls[0] = action("library.profile-default", "保存默认配置", commands[70], edit_enabled);
    content.profile_controls[1] = action("library.profile-alternate", "保存备用配置", commands[71], edit_enabled);
    content.profile_controls[2] = action("library.profile-reset", "重置默认", commands[72], edit_enabled);
    content.profile_controls[3] = action("library.profile-clear", "清除备用", commands[73], edit_enabled);
    content.profile_group[2] = horizontal("library.profile.actions", &content.profile_controls);
    content.profile_launch[0] = action("library.start-alternate", "按备用配置启动", commands[74], launch_enabled);
    content.profile_launch[1] = action("library.start-custom", "按输入配置单次启动", commands[75], launch_enabled);
    content.profile_group[3] = horizontal("library.profile.launch", &content.profile_launch);
    content.profile_group[4] = action("library.detail", "验证并读取素材详情", commands[76], edit_enabled);
    var result = ui.node(ui.NodeKind.stack);
    result.id = abi.view("library.profile.group");
    result.children = .{ .present = 1, .data = &content.profile_group, .count = content.profile_group.len };
    return result;
}

fn fillLocalDetail(content: *Content, id: u64, detail: *const library.AssetDetail) ui.Node {
    const title_text = std.fmt.bufPrint(&content.local_detail_title, "#{d} · {s}", .{ id, detail.name[0..detail.name_len] }) catch unreachable;
    const info_text = std.fmt.bufPrint(&content.local_detail_info, "已核对双摘要 · V{d} · 动作 {d} · 换装 {d} · 定时规则 {d}", .{ detail.version, detail.activities, detail.outfits, detail.rules }) catch unreachable;
    content.local_detail_nodes[0] = changingLabel(&content.local_detail_ids[0], "library.detail.title", title_text);
    content.local_detail_nodes[1] = changingLabel(&content.local_detail_ids[1], "library.detail.info", info_text);
    content.local_detail_nodes[2] = changingLabel(&content.local_detail_ids[2], "library.detail.description", detail.description[0..detail.description_len]);
    content.local_detail_nodes[3] = label("library.detail.preview", "图像预览尚未通过宿主资源接口验证；作者及许可未由素材协议验证。");
    var result = ui.node(ui.NodeKind.stack);
    result.id = abi.view("library.detail.group");
    result.children = .{ .present = 1, .data = &content.local_detail_nodes, .count = content.local_detail_nodes.len };
    return result;
}

// The pinned model schema permits at most 32 states. Keep the existing
// eleven and fifteen bounded editor states, even on the legacy layout.
const policy_keys = [_][]const u8{
    "policy.automatic", "policy.batch",   "policy.interval", "policy.grace",            "policy.timeout",
    "policy.entry.1",   "policy.entry.2", "policy.entry.3",  "policy.entry.4",          "policy.entry.5",
    "policy.entry.6",   "policy.entry.7", "policy.entry.8",  "policy.hide-on-minimize", "policy.retain-history",
};

fn nativePolicyEditor(instance: *const Instance) bool {
    const panel = instance.panel orelse return false;
    return panel.table.get_state != null and panel.table.set_states != null;
}

fn policyEditorStates(policy: *const library.RuntimePolicy, buffers: *[15][64]u8, states: []ui.State) void {
    states[0] = .{ .key = abi.view(policy_keys[0]), .value = abi.view(if (policy.automatic) "true" else "false") };
    const numbers = [_]u64{ @intCast(policy.batch_size), policy.interval_ms, policy.grace_ms, policy.timeout_ms };
    for (numbers, 1..) |number, n| {
        const value = std.fmt.bufPrint(&buffers[n], "{d}", .{number}) catch unreachable;
        states[n] = .{ .key = abi.view(policy_keys[n]), .value = abi.view(value) };
    }
    for (0..8) |n| {
        const value = if (n >= policy.count) "" else blk: {
            const entry = policy.entries[n];
            break :blk if (entry.asset_id == library.builtin_asset_id)
                std.fmt.bufPrint(&buffers[5 + n], "builtin:{d}:{d}", .{ entry.count, entry.profile }) catch unreachable
            else
                std.fmt.bufPrint(&buffers[5 + n], "{d}:{d}:{d}", .{ entry.asset_id, entry.count, entry.profile }) catch unreachable;
        };
        states[5 + n] = .{ .key = abi.view(policy_keys[5 + n]), .value = abi.view(value) };
    }
    states[13] = .{ .key = abi.view(policy_keys[13]), .value = abi.view(if (policy.hide_on_minimize) "true" else "false") };
    states[14] = .{ .key = abi.view(policy_keys[14]), .value = abi.view(if (policy.retain_history) "true" else "false") };
}

fn decodePolicyFields(fields: *const [15][]const u8) !library.RuntimePolicy {
    const automatic: u8 = if (std.mem.eql(u8, fields[0], "true")) 1 else if (std.mem.eql(u8, fields[0], "false")) 0 else return error.InvalidPolicy;
    for (fields[1..5]) |field| {
        if (field.len == 0 or field.len > 16) return error.InvalidPolicy;
        for (field) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidPolicy;
    }
    var encoded: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&encoded, "{d}:{s}:{s}:{s}:{s}", .{ automatic, fields[1], fields[2], fields[3], fields[4] });
    var len = head.len;
    const hide = if (std.mem.eql(u8, fields[13], "true")) true else if (std.mem.eql(u8, fields[13], "false")) false else return error.InvalidPolicy;
    const retain = if (std.mem.eql(u8, fields[14], "true")) true else if (std.mem.eql(u8, fields[14], "false")) false else return error.InvalidPolicy;
    if (hide or retain) {
        const flag = try std.fmt.bufPrint(encoded[len..], ":{d}", .{@intFromBool(hide)});
        len += flag.len;
    }
    if (retain) {
        const flag = try std.fmt.bufPrint(encoded[len..], ":1", .{});
        len += flag.len;
    }
    for (fields[5..13]) |field| {
        if (field.len == 0) continue;
        if (field.len >= 64 or std.mem.indexOfScalar(u8, field, ';') != null) return error.InvalidPolicy;
        const tail = try std.fmt.bufPrint(encoded[len..], ";{s}", .{field});
        len += tail.len;
    }
    return library.RuntimePolicy.decode(encoded[0..len]);
}

fn policyInput(key: []const u8, prompt: []const u8, enabled: bool) ui.Node {
    var node = ui.node(ui.NodeKind.text_input);
    node.id = abi.view(key);
    node.state = .{ .present = 1, .value = abi.view(key) };
    node.placeholder = .{ .present = 1, .value = abi.view(prompt) };
    node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
    return node;
}

fn fillPolicyEditor(content: *Content, enabled: bool) ui.Node {
    content.policy_nodes[0] = ui.node(ui.NodeKind.checkbox);
    content.policy_nodes[0].id = abi.view(policy_keys[0]);
    content.policy_nodes[0].state = .{ .present = 1, .value = abi.view(policy_keys[0]) };
    content.policy_nodes[0].text = .{ .present = 1, .value = abi.view("Pulse 插件激活时自动执行已保存计划") };
    content.policy_nodes[0].enabled = .{ .present = 1, .value = @intFromBool(enabled) };
    content.policy_nodes[1] = label("policy.launch-help", "每批数量（1–16）与批次间隔（100–3000 ms）");
    content.policy_numeric[0] = policyInput(policy_keys[1], "每批数量", enabled);
    content.policy_numeric[1] = policyInput(policy_keys[2], "间隔 ms", enabled);
    content.policy_nodes[2] = horizontal("policy.launch-fields", content.policy_numeric[0..2]);
    content.policy_nodes[3] = label("policy.stop-help", "协作退出（0–5000 ms）与总超时（不超过 10000 ms，至少多 2000 ms）");
    content.policy_numeric[2] = policyInput(policy_keys[3], "协作退出 ms", enabled);
    content.policy_numeric[3] = policyInput(policy_keys[4], "总超时 ms", enabled);
    content.policy_nodes[4] = horizontal("policy.stop-fields", content.policy_numeric[2..4]);
    content.policy_nodes[5] = label("policy.entries-help", "最多八项；每行：素材ID:数量:配置（0默认/1备用）；builtin 为内置；空行忽略。");
    for (0..8) |n| content.policy_nodes[6 + n] = policyInput(policy_keys[5 + n], "例如 builtin:2:0", enabled);
    content.policy_nodes[14] = ui.node(ui.NodeKind.checkbox);
    content.policy_nodes[14].id = abi.view(policy_keys[13]);
    content.policy_nodes[14].state = .{ .present = 1, .value = abi.view(policy_keys[13]) };
    content.policy_nodes[14].text = .{ .present = 1, .value = abi.view("Pulse 主窗口全部最小化时自动隐藏（兼容回退，默认关闭）") };
    content.policy_nodes[14].enabled = .{ .present = 1, .value = @intFromBool(enabled) };
    content.policy_nodes[15] = ui.node(ui.NodeKind.checkbox);
    content.policy_nodes[15].id = abi.view(policy_keys[14]);
    content.policy_nodes[15].state = .{ .present = 1, .value = abi.view(policy_keys[14]) };
    content.policy_nodes[15].text = .{ .present = 1, .value = abi.view("保留脱敏会话历史（16条 / 30天，默认关闭）") };
    content.policy_nodes[15].enabled = .{ .present = 1, .value = @intFromBool(enabled) };
    content.policy_nodes[16] = label("policy.host-boundary", "Windows 登录启动由 Pulse 自身设置管理；无法识别宿主窗口时不自动隐藏。关闭历史记录后不新增记录。");
    var node = ui.node(ui.NodeKind.stack);
    node.id = abi.view("settings.policy-editor");
    ui.withChildren(&node, &content.policy_nodes);
    return node;
}

fn syncPolicyEditor(instance: *Instance) void {
    if (!nativePolicyEditor(instance)) return;
    const panel = if (instance.panel) |*value| value else return;
    var states: [16]ui.State = undefined;
    var fields: [15][64]u8 = undefined;
    var legacy: [512]u8 = undefined;
    const encoded = instance.runtime_policy.encode(&legacy) catch unreachable;
    states[0] = .{ .key = abi.view("settings.runtime-policy"), .value = abi.view(encoded) };
    policyEditorStates(&instance.runtime_policy, &fields, states[1..]);
    panel.setStates(&states) catch {
        instance.policy_sync_failed = true;
        instance.status = "已读取保存值，但无法同步编辑控件；请重新读取后再编辑";
        return;
    };
    instance.policy_sync_failed = false;
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
            content.children[3] = searchInput("library.query", "搜索素材来源 ID、编号或标签");
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
                    content.children[count] = fillProfileControls(content, edit_enabled, instance.task_id == 0 and !instance.stop_requested and (instance.runtime_task_id == 0 or (live and instance.session.canStart())));
                    count += 1;
                    if (instance.library_detail) |*detail| {
                        content.children[count] = fillLocalDetail(content, detail.id, &detail.detail);
                        count += 1;
                    }
                }
                for (snapshot.rows[instance.library_offset..end], 0..) |*row, n| {
                    const suffix = if (instance.recovery_report) |*report| recoverySuffix(report, row.id) else "";
                    const normal = profileText(row.default_profile, &content.profile_line[n]);
                    var alternate_buf: [96]u8 = undefined;
                    const alternate = if (row.alternate_profile) |profile| profileText(profile, &alternate_buf) else "未设置";
                    const body = std.fmt.bufPrint(&content.row_text[n], "#{d}  {s} · {s} · {s} · 标签 {d} {s}{s} · 默认 {s} · 备用 {s}", .{ row.id, row.sourceId(), if (row.paired) "双摘要记录" else "待重验", if (row.favorite) "已收藏" else "未收藏", row.tag_count, row.first_tag[0..row.first_tag_len], suffix, normal, alternate }) catch unreachable;
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
            content.children[3] = searchInput("running.query", "搜索素材来源、实例编号、素材编号或 PID");
            content.children[4] = horizontal("running.toolbar", content.toolbar[0..2]);
            const readable = if (instance.panel) |panel| panel.table.get_state != null else false;
            const clearable = if (instance.panel) |panel| panel.table.set_states != null else false;
            content.running_search_toolbar[0] = action("running.search", "搜索", commands[29], readable);
            content.running_search_toolbar[1] = action("running.search-clear", "清空搜索", commands[30], clearable);
            content.children[5] = horizontal("running.search-actions", if (instance.running_search_token != 0) content.running_search_toolbar[1..2] else &content.running_search_toolbar);
            count = 6;
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
                content.children[6] = changingLabel(&content.dynamic_ids[1], "running.metrics", status);
                count = 7;
                if (instance.running_rows.count != 0) {
                    content.stop_toolbar[0] = ui.node(ui.NodeKind.text_input);
                    content.stop_toolbar[0].id = abi.view("running.stop-id");
                    content.stop_toolbar[0].state = .{ .present = 1, .value = abi.view("running.stop-id") };
                    content.stop_toolbar[0].placeholder = .{ .present = 1, .value = abi.view("输入实例 ID") };
                    const can_stop = !instance.stop_requested and instance.session.pending_stop.load(.acquire) == 0 and instance.session.stopping_id.load(.acquire) == 0 and phase == .running and !instance.session.pending_start.load(.acquire);
                    content.stop_toolbar[1] = action("running.stop-one", "停止指定实例", commands[14], can_stop);
                    content.children[count] = horizontal("running.stop-toolbar", &content.stop_toolbar);
                    count += 1;
                    const total = runningMatchCount(instance);
                    const offset = runningPageStart(instance.running_offset, total);
                    var matched: usize = 0;
                    var rendered: usize = 0;
                    const count_index = count;
                    count += 1;
                    for (instance.running_rows.rows[0..instance.running_rows.count], 0..) |item, n| {
                        const source = instance.running_rows.sources[n].text();
                        if (!runningMatches(item, source, instance.running_query[0..instance.running_query_len])) continue;
                        matched += 1;
                        if (matched <= offset) continue;
                        if (rendered == running_page_size) break;
                        const slot = rendered;
                        rendered += 1;
                        const name = if (source.len != 0) source else "来源未采集";
                        const state = switch (item.state) {
                            .starting => "启动中",
                            .running => switch (instance.running_rows.sources[n].visibility) {
                                .unknown => "运行中 · 可见性未知",
                                .visible => "运行中 · 已确认显示",
                                .hidden => "运行中 · 已确认隐藏",
                                .pending_show => "运行中 · 等待显示确认",
                                .pending_hide => "运行中 · 等待隐藏确认",
                            },
                            .stopping => "正在退出",
                        };
                        const body = if (item.metrics) |metrics| blk: {
                            if (metrics.cpu_core_percent) |cpu| {
                                break :blk std.fmt.bufPrint(&content.row_text[slot], "ID {d} · {s} · 素材 {d} · {s} · PID {d} · CPU {d:.1}% · 工作集 {d} KiB · 私有 {d} KiB · 句柄 {d}", .{ item.id, name, item.asset_id, state, metrics.pid, cpu, metrics.working_set / 1024, metrics.private_bytes / 1024, metrics.handles }) catch unreachable;
                            }
                            break :blk std.fmt.bufPrint(&content.row_text[slot], "ID {d} · {s} · 素材 {d} · {s} · PID {d} · CPU — · 工作集 {d} KiB · 私有 {d} KiB · 句柄 {d}", .{ item.id, name, item.asset_id, state, metrics.pid, metrics.working_set / 1024, metrics.private_bytes / 1024, metrics.handles }) catch unreachable;
                        } else std.fmt.bufPrint(&content.row_text[slot], "ID {d} · {s} · 素材 {d} · {s} · 暂无资源采样", .{ item.id, name, item.asset_id, state }) catch unreachable;
                        const profile = instance.running_rows.sources[n];
                        const full_body = if (profile.id == item.id) blk: {
                            const initial = profileText(profile.profile, &content.profile_line[slot]);
                            const tail = std.fmt.bufPrint(content.row_text[slot][body.len..], " · 启动配置 {s}", .{initial}) catch unreachable;
                            break :blk content.row_text[slot][0 .. body.len + tail.len];
                        } else body;
                        const id = std.fmt.bufPrint(&content.row_ids[slot], "instance-{x}-{x}", .{ item.id, std.hash.Wyhash.hash(0, full_body) }) catch unreachable;
                        content.children[count] = label(id, full_body);
                        count += 1;
                    }
                    const line = std.fmt.bufPrint(&content.running_count, "匹配 {d} / {d} 个实例 · 显示 {d}–{d}", .{ total, instance.running_rows.count, if (total == 0) 0 else offset + 1, offset + rendered }) catch unreachable;
                    content.children[count_index] = changingLabel(&content.running_count_id, "running.count", line);
                    if (total > running_page_size) {
                        content.running_paging[0] = action("running.previous", "上一页", commands[53], offset != 0);
                        content.running_paging[1] = action("running.next", "下一页", commands[54], offset + rendered < total);
                        content.children[count] = horizontal("running.pagination", &content.running_paging);
                        count += 1;
                    }
                    if (total == 0) {
                        content.children[count] = label("running.no-match", "没有匹配的实例，请调整搜索词。");
                        count += 1;
                    }
                    const can_visibility = phase == .running and !instance.stop_requested and !instance.session.visibility_busy.load(.acquire) and instance.session.visibility_id.load(.acquire) == 0;
                    content.visibility_actions[0] = action("running.hide", "隐藏指定 ID", commands[83], can_visibility and readable);
                    content.visibility_actions[1] = action("running.show", "显示指定 ID", commands[84], can_visibility and readable);
                    content.visibility_actions[2] = action("running.hide-all", "全部隐藏", commands[85], can_visibility);
                    content.visibility_actions[3] = action("running.show-all", "全部显示", commands[86], can_visibility);
                    content.children[count] = horizontal("running.visibility", &content.visibility_actions);
                    count += 1;
                }
            }
            if (live and instance.session.plan_active.load(.acquire)) {
                const plan = std.fmt.bufPrint(&content.plan_status, "启动计划：已创建 {d}/{d} · 已尝试 {d}", .{ instance.session.plan_launched.load(.acquire), instance.session.policy.total(), instance.session.plan_attempted.load(.acquire) }) catch unreachable;
                content.children[count] = changingLabel(&content.plan_status_id, "running.plan-status", plan);
                count += 1;
                content.children[count] = action("running.plan-cancel", "取消剩余启动", commands[82], true);
                count += 1;
            }
        },
        .market => count = fillMarket(instance, content),
        .global => {
            const value = if (instance.loaded) std.fmt.bufPrint(&content.value, "已保存的下载并发偏好：{d}（1–8）", .{instance.saved}) catch unreachable else "下载并发偏好尚未确认";
            content.children[2] = changingLabel(&content.dynamic_ids[2], "settings.value", value);
            content.children[3] = changingLabel(&content.dynamic_ids[3], "settings.status", instance.status);
            content.toolbar[0] = action("settings.refresh", "重新读取", commands[4], instance.resources != null and instance.pending == 0);
            content.toolbar[1] = action("settings.less", "减少并发", commands[5], instance.loaded and instance.pending == 0 and instance.saved > 1);
            content.toolbar[2] = action("settings.more", "增加并发", commands[6], instance.loaded and instance.pending == 0 and instance.saved < 8);
            content.children[4] = horizontal("settings.toolbar", content.toolbar[0..3]);
            const limits = instance.runtime_limits;
            const limits_text = std.fmt.bufPrint(&content.limits_text, "实例上限 {d} · 提交内存预算 {d} MiB · 有效上限 {d}（每实例预留 128 MiB；系统资源不足仍会拒绝启动）", .{ limits.instances, limits.commit_mib, limits.effective() }) catch unreachable;
            content.children[5] = changingLabel(&content.limits_id, "settings.limits", limits_text);
            const editable = instance.loaded and instance.pending == 0 and instance.runtime_task_id == 0;
            content.limits_inputs[0] = ui.node(ui.NodeKind.text_input);
            content.limits_inputs[0].id = abi.view("settings.instances");
            content.limits_inputs[0].state = .{ .present = 1, .value = abi.view("settings.instances") };
            content.limits_inputs[0].placeholder = .{ .present = 1, .value = abi.view("实例上限（1–1024）") };
            content.limits_inputs[0].enabled = .{ .present = 1, .value = @intFromBool(editable) };
            content.limits_inputs[1] = ui.node(ui.NodeKind.text_input);
            content.limits_inputs[1].id = abi.view("settings.commit-mib");
            content.limits_inputs[1].state = .{ .present = 1, .value = abi.view("settings.commit-mib") };
            content.limits_inputs[1].placeholder = .{ .present = 1, .value = abi.view("内存预算 MiB（128–131072）") };
            content.limits_inputs[1].enabled = .{ .present = 1, .value = @intFromBool(editable) };
            content.children[6] = horizontal("settings.runtime-inputs", &content.limits_inputs);
            content.children[7] = action("settings.limits-save", "保存运行限制（下次启动生效）", commands[52], editable);
            const policy_editable = editable and instance.task_id == 0 and !instance.auto_pending and !instance.policy_sync_failed;
            if (nativePolicyEditor(instance)) {
                content.children[8] = label("settings.policy-help", "启动与退出策略（保存后下次会话生效；自动默认关闭）");
                content.children[9] = fillPolicyEditor(content, policy_editable);
            } else {
                content.children[8] = label("settings.policy-help", "旧宿主兼容编辑：自动(0/1):每批数量:间隔ms:协作退出ms:总超时ms[:最小化隐藏0/1][:保留历史0/1]；追加 ;素材ID:数量:配置(0默认/1备用)。");
                content.children[9] = policyInput("settings.runtime-policy", "0:4:500:2000:10000;builtin:2:0", policy_editable);
            }
            content.policy_actions[0] = action("settings.policy-save", "保存启动与退出策略", commands[80], policy_editable);
            content.policy_actions[1] = action("settings.plan-start", "执行已保存启动计划", commands[81], policy_editable and instance.runtime_policy.count != 0);
            content.policy_actions[2] = action("settings.plan-cancel", "取消剩余启动", commands[82], instance.runtime_task_id != 0 and instance.session.plan_active.load(.acquire));
            content.children[10] = horizontal("settings.policy-actions", &content.policy_actions);
            content.children[11] = action("settings.diagnostics", "导出脱敏诊断到临时目录", commands[87], instance.active and instance.task_id == 0 and instance.tasks != null and instance.dispatch != null);
            const diagnostic = if (instance.diagnostic_pending) "正在导出脱敏诊断" else if (instance.diagnostic_path_len != 0) instance.diagnostic_path[0..instance.diagnostic_path_len] else instance.diagnostic_status;
            content.children[12] = changingLabel(&content.diagnostic_id, "settings.diagnostic-status", diagnostic);
            count = 13;
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
    content.states[5] = .{ .key = abi.view("running.query"), .value = abi.view(instance.running_query[0..instance.running_query_len]) };
    content.states[6] = .{ .key = abi.view("market.query"), .value = abi.view(instance.market_query.query[0..instance.market_query.len]) };
    const limit_count = std.fmt.bufPrint(&content.limits_count, "{d}", .{instance.runtime_limits.instances}) catch unreachable;
    const limit_memory = std.fmt.bufPrint(&content.limits_memory, "{d}", .{instance.runtime_limits.commit_mib}) catch unreachable;
    content.states[7] = .{ .key = abi.view("settings.instances"), .value = abi.view(limit_count) };
    content.states[8] = .{ .key = abi.view("settings.commit-mib"), .value = abi.view(limit_memory) };
    content.states[9] = .{ .key = abi.view("library.profile"), .value = abi.view("100:0:0") };
    const policy_value = instance.runtime_policy.encode(&content.policy_text) catch unreachable;
    content.states[10] = .{ .key = abi.view("settings.runtime-policy"), .value = abi.view(policy_value) };
    policyEditorStates(&instance.runtime_policy, &content.policy_fields, content.states[11..]);
    tree.states = &content.states;
    tree.state_count = content.states.len;
}

fn rejectMarketImage(instance: *Instance) void {
    instance.market_image_test = false;
    instance.market_image_rejected = true;
}

fn refresh(instance: *Instance) void {
    if (!instance.active) return;
    if (instance.panel) |*panel| {
        var content: Content = undefined;
        var tree: ui.Tree = undefined;
        fill(instance, &content, &tree);
        panel.update(&tree) catch |err| {
            diag.status("companion-update-failed", @intFromError(err));
            if (instance.section == .market and instance.market_image_test) {
                rejectMarketImage(instance);
                fill(instance, &content, &tree);
                panel.update(&tree) catch |fallback_err| diag.status("companion-image-fallback-failed", @intFromError(fallback_err));
            }
        };
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

fn readRuntimeLimits(settings: raw.PulseSettings) !library.RuntimeLimits {
    if (settings.version > (1 << 53) - 1 or settings.count > 1024 or (settings.count != 0 and settings.values == null)) return error.InvalidSettings;
    var found: ?library.RuntimeLimits = null;
    for (0..settings.count) |n| {
        const pair = settings.values[n];
        const key = abi.slice(pair.key) orelse continue;
        if (!std.mem.eql(u8, key, runtime_preference)) continue;
        if (found != null) return error.InvalidSettings;
        found = try library.RuntimeLimits.decode(abi.slice(pair.value) orelse return error.InvalidSettings);
    }
    return found orelse .{};
}

const policy_preference = "runtime.policy";

fn readRuntimePolicy(settings: raw.PulseSettings) !library.RuntimePolicy {
    if (settings.version > (1 << 53) - 1 or settings.count > 1024 or (settings.count != 0 and settings.values == null)) return error.InvalidSettings;
    var found: ?library.RuntimePolicy = null;
    for (0..settings.count) |n| {
        const pair = settings.values[n];
        const key = abi.slice(pair.key) orelse continue;
        if (!std.mem.eql(u8, key, policy_preference)) continue;
        if (found != null) return error.InvalidSettings;
        found = try library.RuntimePolicy.decode(abi.slice(pair.value) orelse return error.InvalidSettings);
    }
    return found orelse .{};
}

fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (reply == null or reply[0].size < @sizeOf(raw.PulseResourcesReply) or instance.pending == 0 or reply[0].request_id != instance.pending) return;
    const operation = instance.pending_operation;
    const policy_changed = instance.policy_write_pending;
    instance.policy_write_pending = false;
    instance.pending = 0;
    instance.pending_operation = 0;
    instance.loaded = false;
    if (!instance.active) return;
    const value = &reply[0];
    if (value.operation != operation or value.status != abi.ok) {
        instance.status = "设置读取或写入失败；请重新读取（可能存在版本冲突）";
    } else if (readPreference(value.settings)) |saved| {
        const limits = readRuntimeLimits(value.settings) catch {
            instance.status = "运行限制设置无效；未覆盖原有设置";
            refresh(instance);
            return;
        };
        const policy = readRuntimePolicy(value.settings) catch {
            instance.status = "运行策略无效；不自动启动";
            instance.auto_pending = false;
            instance.auto_considered = true;
            refresh(instance);
            return;
        };
        instance.saved = saved;
        instance.runtime_limits = limits;
        instance.runtime_policy = policy;
        if (!instance.auto_considered and operation == raw.PULSE_RESOURCES_SETTINGS_GET) {
            instance.auto_considered = true;
            instance.auto_pending = policy.automatic and policy.count != 0 and instance.runtime_task_id == 0;
        }
        instance.version = value.settings.version;
        instance.loaded = true;
        instance.status = if (operation == raw.PULSE_RESOURCES_SETTINGS_SET) "偏好已确认保存；下次下载队列和运行会话采用新设置" else "已读取设置（未配置时采用默认值）";
        if (operation == raw.PULSE_RESOURCES_SETTINGS_GET or policy_changed) syncPolicyEditor(instance);
    } else |_| {
        instance.status = "宿主设置数据无效；未覆盖原有设置";
    }
    maybeAutoStart(instance);
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
    if (next < 1 or next > 8) return;
    const value = [_]u8{'0' + next};
    saveSetting(instance, preference, &value);
}

fn saveLimits(instance: *Instance) void {
    if (!instance.loaded or instance.pending != 0 or instance.runtime_task_id != 0) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var count: [16]u8 = undefined;
    var memory: [16]u8 = undefined;
    var count_len: u32 = 0;
    var memory_len: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("settings.instances"), &count, count.len, &count_len) != abi.ok or count_len >= count.len or get_state(panel.table.context, panel.id, abi.view("settings.commit-mib"), &memory, memory.len, &memory_len) != abi.ok or memory_len >= memory.len) {
        instance.status = "无法读取运行限制输入";
        refresh(instance);
        return;
    }
    const limits = library.RuntimeLimits.parse(count[0..count_len], memory[0..memory_len]) catch {
        instance.status = "运行限制无效；请检查实例数量和 MiB 预算";
        refresh(instance);
        return;
    };
    var value: [32]u8 = undefined;
    const encoded = std.fmt.bufPrint(&value, "{d}:{d}", .{ limits.instances, limits.commit_mib }) catch unreachable;
    saveSetting(instance, runtime_preference, encoded);
}

fn savePolicy(instance: *Instance) void {
    if (!instance.loaded or instance.pending != 0 or instance.runtime_task_id != 0 or instance.task_id != 0 or instance.auto_pending or instance.policy_sync_failed) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    const policy = blk: {
        if (nativePolicyEditor(instance)) {
            var buffers: [15][64]u8 = undefined;
            var values: [15][]const u8 = undefined;
            for (policy_keys, 0..) |key, n| {
                var needed: u32 = 0;
                if (get_state(panel.table.context, panel.id, abi.view(key), &buffers[n], buffers[n].len, &needed) != abi.ok or needed >= buffers[n].len) {
                    instance.status = "无法读取启动策略控件；未保存";
                    refresh(instance);
                    return;
                }
                values[n] = buffers[n][0..needed];
            }
            break :blk decodePolicyFields(&values);
        }
        var bytes: [513]u8 = undefined;
        var needed: u32 = 0;
        if (get_state(panel.table.context, panel.id, abi.view("settings.runtime-policy"), &bytes, bytes.len, &needed) != abi.ok or needed > 512) return;
        break :blk library.RuntimePolicy.decode(bytes[0..needed]);
    } catch {
        instance.status = "运行策略格式或范围无效；未保存";
        refresh(instance);
        return;
    };
    if (policy.total() > instance.runtime_limits.effective()) {
        instance.status = "启动计划超过有效资源上限；未保存";
        refresh(instance);
        return;
    }
    var encoded: [512]u8 = undefined;
    const value = policy.encode(&encoded) catch return;
    instance.policy_write_pending = true;
    saveSetting(instance, policy_preference, value);
    if (instance.pending == 0) instance.policy_write_pending = false;
}

fn saveSetting(instance: *Instance, key: []const u8, value: []const u8) void {
    const resources = instance.resources orelse return;
    if (!instance.loaded or instance.pending != 0) return;
    const set = resources.settings_set orelse return;
    var request: u64 = 0;
    const status = set(resources.context, abi.view(key), abi.view(value), 0, instance.version, completed, instance, &request);
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
    if (instance.diagnostic_pending) {
        const report = &instance.diagnostic_report;
        var len = instance.diagnostic_report_len;
        if (instance.diagnostic_history_allowed) {
            const extra = library.appendDiagnosticHistory(config.runtime_sha256, report[len..]) catch |err| blk: {
                if (err == error.CleanupFailed) {
                    instance.work_error = err;
                    return raw.PULSE_TASK_FAILED;
                }
                const line = std.fmt.bufPrint(report[len..], "\nretained_history_status: {s}\n", .{@errorName(err)}) catch {
                    instance.work_error = error.InvalidDiagnostic;
                    return raw.PULSE_TASK_FAILED;
                };
                break :blk line.len;
            };
            len += extra;
        } else {
            const line = std.fmt.bufPrint(report[len..], "\nretained_history_status: active_session\n", .{}) catch unreachable;
            len += line.len;
        }
        if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
        instance.diagnostic_report_len = len;
        instance.diagnostic_path_len = library.exportDiagnostic(instance.diagnostic_report[0..instance.diagnostic_report_len], &instance.diagnostic_path) catch |err| {
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
        return raw.PULSE_TASK_COMPLETED;
    }
    if (instance.market_browser_pending) {
        library.openMarketGallery() catch |err| {
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
        return raw.PULSE_TASK_COMPLETED;
    }
    if (instance.market_request) |*request| {
        library.marketDefault(config.runtime_sha256, config.helper_sha256, request, &instance.market_outcome, &instance.market_progress, .{ .callback = canceled, .context = context[0].context }) catch |err| {
            instance.work_error = err;
            if (err == error.Canceled) return raw.PULSE_TASK_CANCELLED;
            return raw.PULSE_TASK_FAILED;
        };
        return raw.PULSE_TASK_COMPLETED;
    }
    if (instance.detail_request) |request| {
        instance.detail_work = library.describeDefault(config.runtime_sha256, config.helper_sha256, request, .{ .callback = canceled, .context = context[0].context }) catch |err| {
            if (err == error.Canceled) return raw.PULSE_TASK_CANCELLED;
            instance.work_error = err;
            return raw.PULSE_TASK_FAILED;
        };
        return if (canceled(context[0].context) != 0) raw.PULSE_TASK_CANCELLED else raw.PULSE_TASK_COMPLETED;
    }
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
    maybeAutoStart(instance);
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

fn onRunningSearchChanged(user: ?*anyopaque, panel: u64, batch: [*c]const raw.PulseUiStateBatch) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!instance.active or panel != instance.page or instance.section != .running or instance.running_search_token == 0) return;
    if (batch == null or batch[0].changes == null or batch[0].count > 128) return;
    var changed = false;
    for (0..batch[0].count) |n| {
        const change = batch[0].changes[n];
        if (change.source_mask & @as(u32, raw.PULSE_UI_STATE_USER) == 0 or change.revision <= instance.running_search_revision) continue;
        const key = abi.slice(change.key) orelse continue;
        if (!std.mem.eql(u8, key, "running.query")) continue;
        instance.running_search_revision = change.revision;
        const value = abi.slice(change.value) orelse continue;
        if (!validSearch(value) or std.mem.eql(u8, value, instance.running_query[0..instance.running_query_len])) continue;
        @memcpy(instance.running_query[0..value.len], value);
        instance.running_query_len = value.len;
        instance.running_offset = 0;
        changed = true;
    }
    // Only the copied bounded snapshot is filtered. No process or I/O calls.
    if (changed) refresh(instance);
}

fn manualRunningSearch(instance: *Instance, clear: bool) void {
    const panel = if (instance.panel) |*value| value else return;
    if (clear) {
        const states = [_]ui.State{.{ .key = abi.view("running.query"), .value = abi.view("") }};
        panel.setStates(&states) catch return;
        instance.running_query_len = 0;
    } else {
        const get_state = panel.table.get_state orelse return;
        var bytes: [257]u8 = undefined;
        var needed: u32 = 0;
        if (get_state(panel.table.context, panel.id, abi.view("running.query"), &bytes, bytes.len, &needed) != abi.ok or needed > 256 or !validSearch(bytes[0..needed])) return;
        @memcpy(instance.running_query[0..needed], bytes[0..needed]);
        instance.running_query_len = needed;
    }
    instance.running_offset = 0;
    refresh(instance);
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
    var running_token: u64 = 0;
    if (subscribe(table.context, instance.page, abi.view("running.query"), @intCast(raw.PULSE_UI_STATE_USER), onRunningSearchChanged, instance, &running_token) == abi.ok and running_token != 0) instance.running_search_token = running_token;
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
    if (!terminal(instance.task_state)) {
        if (instance.market_request != null and instance.section == .market) refresh(instance);
        return;
    }
    if (release(tasks.context, instance.task_id) != abi.ok) {
        instance.library_status = "任务释放失败；请重试";
        refresh(instance);
        return;
    }
    diag.status("companion-library-terminal", instance.task_state);
    instance.task_id = 0;
    if (instance.diagnostic_pending) {
        instance.diagnostic_pending = false;
        instance.diagnostic_history_allowed = false;
        if (instance.task_state != raw.PULSE_TASK_COMPLETED or !instance.work_done.load(.acquire) or instance.work_error != null) {
            instance.diagnostic_path_len = 0;
            instance.diagnostic_status = if (instance.work_error) |err| @errorName(err) else "诊断导出未确认";
        } else instance.diagnostic_status = "诊断已导出";
        refresh(instance);
        return;
    }
    if (instance.market_browser_pending) {
        instance.market_browser_pending = false;
        const done = instance.work_done.load(.acquire);
        instance.market_status = if (done and instance.task_state == raw.PULSE_TASK_COMPLETED and instance.work_error == null) "已请求默认浏览器打开官方图库；请在浏览器查看" else if (instance.task_state == raw.PULSE_TASK_CANCELLED) "浏览器请求已取消或未确认；可手动访问 " ++ library.market_gallery_url else "无法确认打开浏览器；请手动访问 " ++ library.market_gallery_url;
        if (instance.active and instance.section == .library and !instance.library_loaded) startLibrary(instance, false);
        refresh(instance);
        return;
    }
    if (instance.market_request) |request| {
        instance.market_request = null;
        instance.market_cancel_requested = false;
        if (request == .install or request == .batch) {
            // Do not reuse the pre-install window after a terminal outcome.
            instance.market_snapshot = .{};
            instance.market_selected = null;
            instance.market_detail = null;
        }
        const done = instance.work_done.load(.acquire);
        if (request == .batch) {
            instance.market_queue_done = true;
            instance.market_queue_cleanup = if (instance.work_error) |err| err == error.MarketCleanupFailed or err == error.CleanupFailed else false;
            for (instance.market_progress.jobs[0..instance.market_queue.count]) |*job| {
                switch (job.get()) {
                    .waiting, .downloading, .installing => job.set(if (instance.task_state == raw.PULSE_TASK_CANCELLED) .canceled else .failed),
                    else => {},
                }
            }
            instance.library_loaded = false;
            instance.library_detail = null;
            instance.recovery_report = null;
            instance.market_status = if (instance.market_queue_cleanup) "队列清理未确认；已提交项仍有效，请检查恢复状态" else if (instance.task_state == raw.PULSE_TASK_CANCELLED) "队列已取消；已提交项仍有效" else if (instance.work_error) |err| @errorName(err) else if (!done or instance.task_state != raw.PULSE_TASK_COMPLETED) "队列未确认完成；请检查本地素材库" else "队列已结束；逐项查看结果，重新搜索后可重试失败项";
        } else if (done and instance.market_outcome.installed != null) {
            instance.library_loaded = false;
            instance.library_detail = null;
            instance.recovery_report = null;
            instance.market_status = if (instance.work_error != null or instance.task_state != raw.PULSE_TASK_COMPLETED) "安装已提交，但任务或临时目录清理未确认；请检查本地素材库，禁止直接重试" else switch (instance.market_outcome.installed.?) {
                .existing => "素材已存在；未重复安装",
                .imported => "安装完成；切换至本地素材库查看",
            };
        } else if (done and instance.task_state == raw.PULSE_TASK_COMPLETED and instance.work_error == null and request == .search) {
            instance.market_snapshot = instance.market_outcome.snapshot;
            instance.market_status = "市场搜索完成";
        } else if (done and instance.task_state == raw.PULSE_TASK_COMPLETED and instance.work_error == null and request == .detail and instance.market_outcome.detail != null) {
            instance.market_detail = instance.market_outcome.detail;
            instance.market_status = "素材详情已读取；安装时仍会重新验证";
        } else {
            instance.market_status = if (instance.task_state == raw.PULSE_TASK_CANCELLED) (if (request == .install) "市场任务已取消；未确认写入请检查本地素材库" else "读取市场信息已取消") else if (done) if (instance.work_error) |err| @errorName(err) else "市场任务未返回有效结果" else "市场任务未完成";
            if (request == .install) {
                instance.library_loaded = false;
                instance.library_detail = null;
                instance.recovery_report = null;
            }
        }
        instance.market_outcome = .{};
        if (instance.active and instance.section == .library and !instance.library_loaded and instance.task_id == 0) startLibrary(instance, false);
        refresh(instance);
        return;
    }
    if (instance.detail_request) |request| {
        instance.detail_request = null;
        const done = instance.work_done.load(.acquire);
        if (done and instance.task_state == raw.PULSE_TASK_COMPLETED and instance.work_error == null and instance.detail_work != null) {
            instance.library_detail = .{ .id = request.id, .detail = instance.detail_work.? };
            instance.library_status = "素材详情已验证；读取时点有效";
        } else {
            instance.library_detail = null;
            instance.library_status = if (instance.task_state == raw.PULSE_TASK_CANCELLED) "已取消素材详情读取" else if (done) if (instance.work_error) |err| @errorName(err) else "素材详情未返回" else "素材详情未完成";
        }
        instance.detail_work = null;
        refresh(instance);
        return;
    }
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
    if (instance.diagnostic_pending or instance.detail_request != null or instance.market_request != null or !instance.active or config.runtime_sha256.len == 0 or instance.runtime_checked or instance.runtime_task_id != 0 or instance.preference_edit != null or instance.import_request != null or instance.import_dialog != 0 or instance.picker_request != 0 or instance.fallback_pick or instance.recovery_scan or instance.removal_request != null or instance.removal_dialog != 0) return;
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
    startAssetProfile(instance, asset_id, .asset_default);
}

fn startAssetProfile(instance: *Instance, asset_id: u64, choice: library.LaunchProfile) void {
    instance.auto_pending = false;
    startSession(instance, asset_id, choice, false);
}

fn maybeAutoStart(instance: *Instance) void {
    if (!instance.auto_pending or !instance.active or !instance.loaded or instance.task_id != 0 or instance.runtime_task_id != 0) return;
    instance.auto_pending = false;
    startPlan(instance);
}

fn startPlan(instance: *Instance) void {
    if (!instance.active or !instance.loaded or instance.pending != 0 or instance.task_id != 0 or instance.runtime_task_id != 0 or instance.runtime_policy.count == 0) return;
    if (instance.runtime_policy.total() > instance.runtime_limits.effective()) {
        instance.runtime_status = "启动计划超过有效资源上限；未启动";
        refresh(instance);
        return;
    }
    if (instance.dispatch == null or config.runtime_sha256.len != 64 or config.helper_sha256.len != 64) {
        instance.runtime_status = "启动计划不可用；缺少宿主调度或同包运行时";
        refresh(instance);
        return;
    }
    const first = instance.runtime_policy.at(0) orelse return;
    const choice = library.LaunchProfile.unpack(first.profile) catch return;
    startSession(instance, first.asset_id, choice, true);
}

fn startSession(instance: *Instance, asset_id: u64, choice: library.LaunchProfile, planned: bool) void {
    const packed_profile = choice.pack() catch return;
    if (instance.diagnostic_pending or instance.detail_request != null or instance.market_request != null or !instance.active or config.runtime_sha256.len != 64 or config.helper_sha256.len != 64 or instance.dispatch == null or instance.stop_requested or instance.preference_edit != null or instance.import_request != null or instance.import_dialog != 0 or instance.picker_request != 0 or instance.fallback_pick or instance.recovery_scan or instance.removal_request != null or instance.removal_dialog != 0 or asset_id == 0) return;
    if (instance.runtime_task_id != 0) {
        if (instance.task_kind != .builtin_session) return;
        instance.runtime_status = if (instance.session.requestAssetProfile(asset_id, choice)) "已提交新增实例请求" else "暂不可新增实例；请等待或停止";
        refresh(instance);
        return;
    }
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    instance.runtime_done.store(false, .release);
    instance.runtime_error = null;
    instance.session.reset();
    instance.session.limits = instance.runtime_limits;
    instance.session.policy = instance.runtime_policy;
    instance.session.planned = planned;
    instance.session.plan_active.store(planned, .release);
    instance.running_offset = 0;
    instance.session.start_profile.store(packed_profile, .release);
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

fn setVisibility(instance: *Instance, all: bool, show: bool) void {
    if (instance.runtime_task_id == 0 or instance.task_kind != .builtin_session or instance.stop_requested) return;
    const id = if (all) std.math.maxInt(u64) else blk: {
        const panel = instance.panel orelse return;
        const get_state = panel.table.get_state orelse return;
        var bytes: [32]u8 = undefined;
        var needed: u32 = 0;
        if (get_state(panel.table.context, panel.id, abi.view("running.stop-id"), &bytes, bytes.len, &needed) != abi.ok or needed == 0 or needed >= bytes.len) return;
        const selected = std.fmt.parseInt(u64, bytes[0..needed], 10) catch return;
        for (instance.running_rows.rows[0..instance.running_rows.count]) |item| {
            if (item.id == selected and item.state == .running) break :blk selected;
        }
        return;
    };
    instance.runtime_status = if (instance.session.requestVisibility(id, show)) "已提交可见性请求；等待子进程确认" else "可见性请求繁忙或实例未就绪";
    refresh(instance);
}

fn exportDiagnostic(instance: *Instance) void {
    if (!instance.active or instance.task_id != 0 or instance.dispatch == null or instance.import_dialog != 0 or instance.removal_dialog != 0 or instance.picker_request != 0) return;
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    const session = &instance.session;
    const report = std.fmt.bufPrint(&instance.diagnostic_report, "PulseExtras Companion diagnostic v1\nSDK preview: {d}\nconfigured_instances: {d}\ncommit_budget_mib: {d}\neffective_limit: {d}\nstartup_batch: {d}\nstartup_interval_ms: {d}\nshutdown_grace_ms: {d}\nshutdown_timeout_ms: {d}\nowned: {d}\nready: {d}\nworking_set_bytes: {d}\nprivate_bytes: {d}\nlaunch_attempted: {d}\nlaunch_created: {d}\nrejections: {d}\nlast_rejection: {d}\nconfirmed_exits: {d}\nabnormal_exits: {d}\nlast_exit_code: {d}\nhistory_write_status: {d}\nhide_on_minimize: {d}\nhost_window_state: {d}\n", .{ abi.sdk_preview, instance.runtime_limits.instances, instance.runtime_limits.commit_mib, instance.runtime_limits.effective(), instance.runtime_policy.batch_size, instance.runtime_policy.interval_ms, instance.runtime_policy.grace_ms, instance.runtime_policy.timeout_ms, session.owned.load(.acquire), session.ready.load(.acquire), session.working_set.load(.acquire), session.private_bytes.load(.acquire), session.plan_attempted.load(.acquire), session.plan_launched.load(.acquire), session.denied.load(.acquire), session.last_rejection.load(.acquire), session.exits.load(.acquire), session.abnormal_exits.load(.acquire), session.last_exit.load(.acquire), session.history_status.load(.acquire), @intFromBool(instance.runtime_policy.hide_on_minimize), session.host_window_state.load(.acquire) }) catch return;
    instance.diagnostic_report_len = report.len;
    instance.diagnostic_path_len = 0;
    instance.diagnostic_history_allowed = instance.runtime_task_id == 0;
    instance.diagnostic_pending = true;
    instance.work_done.store(false, .release);
    instance.work_error = null;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view("导出桌宠诊断"),
        .type = abi.view("companion.diagnostic"),
        .work = readLibrary,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.task_id = id;
        instance.diagnostic_status = "正在导出脱敏诊断";
        armTimer(instance);
    } else {
        instance.diagnostic_pending = false;
        instance.diagnostic_status = "宿主拒绝诊断任务";
    }
    refresh(instance);
}

fn stopBuiltin(instance: *Instance) void {
    instance.auto_pending = false;
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
    startLibraryProfile(instance, .asset_default);
}

fn startLibraryProfile(instance: *Instance, choice: library.LaunchProfile) void {
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
            if (choice == .alternate and row.alternate_profile == null) {
                instance.library_status = "该素材没有备用配置";
                refresh(instance);
                return;
            }
            startAssetProfile(instance, id, choice);
            instance.section = .running;
            refresh(instance);
            return;
        }
    }
    instance.library_status = "素材不存在、未匹配或需要双摘要重验";
    refresh(instance);
}

fn startLocalDetail(instance: *Instance) void {
    if (!instance.active or !instance.library_loaded or instance.task_id != 0 or instance.runtime_task_id != 0 or instance.import_dialog != 0 or instance.removal_dialog != 0 or instance.picker_request != 0 or config.runtime_sha256.len != 64 or config.helper_sha256.len != 64 or instance.dispatch == null) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var bytes: [32]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("library.asset-id"), &bytes, bytes.len, &needed) != abi.ok or needed == 0 or needed >= bytes.len) return;
    const id = std.fmt.parseInt(u64, bytes[0..needed], 10) catch 0;
    instance.library_detail = null;
    for (instance.library_snapshot.rows[0..instance.library_snapshot.count]) |*row| {
        if (row.id != id) continue;
        instance.detail_request = row.removalRecord() catch |err| {
            instance.library_status = @errorName(err);
            refresh(instance);
            return;
        };
        instance.detail_work = null;
        startLibrary(instance, false);
        if (instance.task_id == 0) instance.detail_request = null;
        refresh(instance);
        return;
    }
    instance.library_status = "请选择当前素材清单中的有效 ID";
    refresh(instance);
}

fn readProfile(instance: *Instance) !library.Profile {
    const panel = instance.panel orelse return error.Invalid;
    const get_state = panel.table.get_state orelse return error.Invalid;
    var bytes: [32]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("library.profile"), &bytes, bytes.len, &needed) != abi.ok or needed == 0 or needed >= bytes.len) return error.Invalid;
    return library.Profile.parse(bytes[0..needed]);
}

fn startCustomProfile(instance: *Instance) void {
    const profile = readProfile(instance) catch {
        instance.library_status = "配置无效，请输入例如125:1:0";
        refresh(instance);
        return;
    };
    startLibraryProfile(instance, .{ .custom = profile });
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
        if (action_kind != .toggle_favorite and action_kind != .add_tag and action_kind != .remove_tag and !row.paired) {
            instance.library_status = "素材需要双摘要重验后才能保存启动配置";
            refresh(instance);
            return;
        }
        var edit: library.PreferenceEdit = .{ .row = row, .action = action_kind };
        if (action_kind == .save_default_profile or action_kind == .save_alternate_profile) {
            edit.profile = readProfile(instance) catch {
                instance.library_status = "配置无效，请输入例如125:1:0";
                refresh(instance);
                return;
            };
        }
        if (action_kind == .add_tag or action_kind == .remove_tag) {
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
    if (instance.detail_request == null) {
        instance.library_detail = null;
        if (!instance.fallback_pick and !instance.recovery_scan) instance.library_loaded = false;
    }
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view(if (instance.detail_request != null) "验证素材详情" else if (instance.fallback_pick) "选择素材文件夹" else if (instance.recovery_scan) "扫描桌宠恢复状态" else if (instance.removal_request != null) "维护桌宠素材" else if (instance.import_request != null) "导入桌宠素材" else if (instance.preference_edit != null) "保存桌宠偏好" else "读取桌宠素材清单"),
        .type = abi.view("companion.library"),
        .work = readLibrary,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.task_id = id;
        instance.library_status = if (instance.detail_request != null) "正在核对素材双摘要及详情" else if (instance.fallback_pick) "正在使用 Windows 文件夹选择器（60 秒超时）" else if (instance.recovery_scan) "正在进行只读恢复扫描" else if (instance.removal_request != null) "正在维护桌宠素材" else if (instance.import_request != null) "正在导入本地素材" else if (instance.preference_edit != null) "正在保存素材偏好" else "正在自动读取素材清单";
        armTimer(instance);
        if (instance.timer == null) instance.library_status = "正在读取；宿主自动刷新不可用，可手动检查";
    } else {
        instance.library_status = "宿主拒绝读取任务";
    }
    refresh(instance);
}

fn openMarketGallery(instance: *Instance) void {
    if (!marketBrowserIdle(instance)) return;
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    instance.market_browser_pending = true;
    instance.work_done.store(false, .release);
    instance.work_error = null;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view("打开 OpenPets 官方图库"),
        .type = abi.view("companion.market.browser"),
        .work = readLibrary,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.task_id = id;
        instance.market_status = "正在请求默认浏览器打开官方图库";
        armTimer(instance);
        if (instance.timer == null) instance.market_status = "正在打开官方图库；自动收集不可用，请手动检查任务状态";
    } else {
        instance.market_browser_pending = false;
        instance.market_status = "宿主拒绝浏览器任务；请手动访问 " ++ library.market_gallery_url;
    }
    refresh(instance);
}

fn startMarket(instance: *Instance, request: library.MarketRequest) void {
    if (!marketIdle(instance)) return;
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    if (request == .search) {
        instance.market_query = request.search;
        instance.market_snapshot = .{};
        instance.market_selected = null;
        instance.market_detail = null;
    }
    if (request == .detail) instance.market_detail = null;
    instance.market_request = request;
    instance.market_outcome = .{};
    if (request == .batch) instance.market_progress.reset() else instance.market_progress.http_progress.reset();
    instance.market_cancel_requested = false;
    instance.work_done.store(false, .release);
    instance.work_error = null;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view(switch (request) {
            .search => "搜索 OpenPets 市场",
            .detail => "读取素材详情",
            .install => "下载并安装桌宠",
            .batch => "并行下载市场队列",
        }),
        .type = abi.view("companion.market"),
        .work = readLibrary,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.task_id = id;
        instance.market_status = switch (request) {
            .search => "正在读取市场目录",
            .detail => "正在读取素材详情",
            .install => "正在下载、校验并安装素材",
            .batch => "并行下载中；安装按序提交",
        };
        armTimer(instance);
    } else {
        instance.market_request = null;
        instance.market_status = "宿主拒绝市场任务";
    }
    refresh(instance);
}

fn searchMarket(instance: *Instance, offline: bool) void {
    if (!marketIdle(instance)) return;
    const panel = instance.panel orelse return;
    const get_state = panel.table.get_state orelse return;
    var bytes: [257]u8 = undefined;
    var needed: u32 = 0;
    if (get_state(panel.table.context, panel.id, abi.view("market.query"), &bytes, bytes.len, &needed) != abi.ok or needed > 256) return;
    var query = library.MarketSearch.init(bytes[0..needed], 0, offline) catch |err| {
        instance.market_status = @errorName(err);
        refresh(instance);
        return;
    };
    query.filters = instance.market_filters;
    if (query.filters.mode == .exact_id and !library.validSourceId(query.query[0..query.len])) {
        instance.market_status = "精确搜索需要有效来源 ID";
        refresh(instance);
        return;
    }
    startMarket(instance, .{ .search = query });
}

fn pageMarket(instance: *Instance, next: bool) void {
    if (!marketIdle(instance)) return;
    const result = instance.market_snapshot.result orelse return;
    var query = instance.market_snapshot.query;
    const size = instance.market_snapshot.rows.len;
    if (next) {
        if (result.summary.written == 0 or query.offset + result.summary.written >= result.summary.total) return;
        query.offset += size;
    } else {
        if (query.offset < size) return;
        query.offset -= size;
    }
    startMarket(instance, .{ .search = query });
}

fn clearMarketSearch(instance: *Instance) void {
    if (instance.market_request != null or instance.task_id != 0) return;
    const panel = if (instance.panel) |*value| value else return;
    const states = [_]ui.State{.{ .key = abi.view("market.query"), .value = abi.view("") }};
    panel.setStates(&states) catch |err| {
        instance.market_status = @errorName(err);
        refresh(instance);
        return;
    };
    instance.market_query = .{};
    instance.market_filters = .{};
    instance.market_snapshot = .{};
    instance.market_selected = null;
    instance.market_detail = null;
    instance.market_status = "已清空搜索；主动搜索后才联网";
    refresh(instance);
}

fn selectMarket(instance: *Instance, index: usize) void {
    if (!marketIdle(instance)) return;
    const request = instance.market_snapshot.detailIndex(index) catch {
        instance.market_selected = null;
        instance.market_detail = null;
        instance.market_status = "素材选择无效；请重新搜索";
        refresh(instance);
        return;
    };
    instance.market_selected = index;
    startMarket(instance, request);
}

fn installMarket(instance: *Instance, full: bool) void {
    if (!marketIdle(instance)) return;
    const selected = instance.market_selected orelse return;
    const detail = instance.market_detail orelse return;
    if (!detail.installable or (full and !detail.wardrobe)) return;
    const request = instance.market_snapshot.selectIndex(selected, full) catch |err| {
        instance.market_status = @errorName(err);
        refresh(instance);
        return;
    };
    startMarket(instance, request);
}

fn queueMarket(instance: *Instance, full: bool) void {
    if (!marketIdle(instance) or instance.market_queue_done) return;
    const selected = instance.market_selected orelse return;
    const detail = instance.market_detail orelse return;
    if (!detail.installable or (full and !detail.wardrobe)) return;
    const request = instance.market_snapshot.selectIndex(selected, full) catch return;
    instance.market_queue.append(request.install) catch |err| {
        instance.market_status = @errorName(err);
        refresh(instance);
        return;
    };
    instance.market_status = "已加入下载队列；开始队列前不会下载";
    refresh(instance);
}

fn startMarketQueue(instance: *Instance) void {
    if (!marketIdle(instance) or instance.market_queue_done or instance.market_queue.count == 0 or !instance.loaded) return;
    instance.market_queue.concurrency = instance.saved;
    startMarket(instance, .{ .batch = instance.market_queue });
}

fn clearMarketQueue(instance: *Instance) void {
    if (!marketIdle(instance)) return;
    instance.market_queue = .{};
    instance.market_queue_done = false;
    instance.market_queue_cleanup = false;
    instance.market_progress.reset();
    refresh(instance);
}

fn marketQueueItem(instance: *Instance, index: usize) void {
    if (index >= instance.market_queue.count) return;
    if (instance.market_request) |request| {
        if (request != .batch) return;
        const job = &instance.market_progress.jobs[index];
        switch (job.get()) {
            .waiting, .downloading, .installing => job.canceled.store(true, .release),
            else => return,
        }
    } else {
        if (!marketIdle(instance) or instance.market_queue_done) return;
        instance.market_queue.remove(index);
    }
    refresh(instance);
}

fn cancelMarket(instance: *Instance) void {
    if (instance.market_request == null or instance.task_id == 0 or instance.market_cancel_requested) return;
    const tasks = instance.tasks orelse return;
    const cancel = tasks.cancel orelse return;
    if (cancel(tasks.context, instance.task_id) == abi.ok) {
        instance.market_cancel_requested = true;
        if (instance.market_request.? == .batch) {
            for (instance.market_progress.jobs[0..instance.market_queue.count]) |*job| {
                switch (job.get()) {
                    .waiting, .downloading, .installing => job.canceled.store(true, .release),
                    else => {},
                }
            }
        }
        instance.market_status = "已请求取消；等待网络或 Helper 安全返回";
    } else {
        instance.market_status = "取消请求失败；仍保留任务所有权";
    }
    refresh(instance);
}

fn changeMarketFilter(instance: *Instance, which: usize) void {
    if (!marketIdle(instance)) return;
    const filters = &instance.market_filters;
    switch (which) {
        0 => {
            filters.mode = switch (filters.mode) {
                .curated => .all,
                .all => .original,
                .original => .featured,
                .featured => .exact_id,
                .exact_id => .curated,
            };
            if (filters.mode == .exact_id) {
                filters.category = .any;
                filters.version = .any;
            }
        },
        1 => {
            if (filters.mode == .exact_id) return;
            filters.category = switch (filters.category) {
                .any => .asian,
                .asian => .western,
                .western => .any,
            };
        },
        2 => {
            if (filters.mode == .exact_id) return;
            filters.version = switch (filters.version) {
                .any => .v1,
                .v1 => .v2,
                .v2 => .any,
            };
        },
        else => return,
    }
    instance.market_snapshot = .{};
    instance.market_selected = null;
    instance.market_detail = null;
    instance.market_status = "筛选条件已变更；请主动搜索";
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
        if (n >= 15 and n <= 28 and instance.section != .library) return;
        if (n >= 29 and n <= 30 and instance.section != .running) return;
        if (n >= 31 and n <= 51 and instance.section != .market) return;
        if (n == 52 and instance.section != .global) return;
        if (n >= 53 and n <= 54 and instance.section != .running) return;
        if (n >= 55 and n <= 69 and instance.section != .market) return;
        if (n >= 70 and n <= 76 and instance.section != .library) return;
        if (n >= 77 and n <= 79 and instance.section != .market) return;
        if ((n == 80 or n == 81 or n == 87) and instance.section != .global) return;
        if (n == 82 and instance.section != .global and instance.section != .running) return;
        if (n >= 83 and n <= 86 and instance.section != .running) return;
        switch (n) {
            0, 1, 2, 3 => {
                instance.section = @fromBackingInt(@intCast(n));
                if (instance.section != .market) instance.market_image_test = false;
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
            29 => manualRunningSearch(instance, false),
            30 => manualRunningSearch(instance, true),
            31 => searchMarket(instance, false),
            32 => searchMarket(instance, true),
            33 => pageMarket(instance, false),
            34 => pageMarket(instance, true),
            35 => installMarket(instance, false),
            36 => installMarket(instance, true),
            37 => cancelMarket(instance),
            38 => pollTasks(instance),
            39 => clearMarketSearch(instance),
            40...51 => selectMarket(instance, n - 40),
            52 => saveLimits(instance),
            70 => startPreference(instance, .save_default_profile),
            71 => startPreference(instance, .save_alternate_profile),
            72 => startPreference(instance, .reset_default_profile),
            73 => startPreference(instance, .clear_alternate_profile),
            74 => startLibraryProfile(instance, .alternate),
            75 => startCustomProfile(instance),
            76 => startLocalDetail(instance),
            77 => {
                if (instance.market_request != null or instance.market_image_rejected) return;
                instance.market_image_test = !instance.market_image_test;
                refresh(instance);
            },
            78 => openMarketGallery(instance),
            79 => {
                if (!instance.market_image_test) return;
                rejectMarketImage(instance);
                refresh(instance);
            },
            80 => savePolicy(instance),
            81 => startPlan(instance),
            82 => {
                instance.auto_pending = false;
                instance.session.plan_cancel.store(true, .release);
                refresh(instance);
            },
            83 => setVisibility(instance, false, false),
            84 => setVisibility(instance, false, true),
            85 => setVisibility(instance, true, false),
            86 => setVisibility(instance, true, true),
            87 => exportDiagnostic(instance),
            55...57 => changeMarketFilter(instance, n - 55),
            58 => queueMarket(instance, false),
            59 => queueMarket(instance, true),
            60 => startMarketQueue(instance),
            61 => clearMarketQueue(instance),
            62...69 => marketQueueItem(instance, n - 62),
            53, 54 => {
                const total = runningMatchCount(instance);
                const offset = runningPageStart(instance.running_offset, total);
                instance.running_offset = if (n == 53) offset -| running_page_size else runningPageStart(offset + running_page_size, total);
                refresh(instance);
            },
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
    instance.policy_write_pending = false;
    instance.policy_sync_failed = false;
    instance.auto_pending = false;
    instance.market_image_test = false;
    instance.market_image_rejected = false;
    instance.runtime_checked = false;
    instance.runtime_status = if (config.runtime_sha256.len == 0) "未打包运行时；无法启动桌宠" else "切换至运行管理时检查同包运行时";
    stopTimer(instance);
    instance.search_pending = false;
    instance.search_ticks = 0;
    if (instance.running_search_token != 0) {
        const events = instance.search_events orelse return error.State;
        const unsubscribe = events.unsubscribe orelse return error.Unavailable;
        host_mod.mapStatus(unsubscribe(events.context, instance.running_search_token)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.running_search_token = 0;
        instance.running_search_revision = 0;
    }
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
    instance.auto_considered = false;
    instance.auto_pending = false;
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
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    for (0..names.len) |n| {
        instance.section = @fromBackingInt(@intCast(n));
        fill(instance, &content, &tree);
        try std.testing.expectEqual(@as(u32, commands.len), tree.command_count);
        try std.testing.expectEqual(@as(u32, 4), content.children[0].children.count);
        try std.testing.expectEqualStrings(commands[n][10..], abi.slice(content.children[1].id).?);
        const expected: u32 = switch (instance.section) {
            .library => 5,
            .global => 13,
            .running => 6,
            .market => 8,
        };
        try std.testing.expectEqual(expected, content.root.children.count);
    }
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[2].enabled.value);
}

test "running view exposes bounded start and stop actions" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .section = .running };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 6), content.root.children.count);
    try std.testing.expectEqual(ui.NodeKind.text_input, content.children[3].type);
    try std.testing.expectEqual(@as(u32, 2), content.children[4].children.count);
    try std.testing.expectEqualStrings(commands[12], abi.slice(content.toolbar[0].command.value).?);
    try std.testing.expectEqualStrings(commands[13], abi.slice(content.toolbar[1].command.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[0].enabled.value);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[1].enabled.value);
    instance.runtime_task_id = 1;
    instance.task_kind = .builtin_session;
    instance.session.set(.running);
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 7), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[0].enabled.value);
    try std.testing.expectEqual(@as(u32, 1), content.toolbar[1].enabled.value);
    instance.stop_requested = true;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[1].enabled.value);
    instance.section = .library;
    instance.tasks = std.mem.zeroes(raw.PulseTasksV1);
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 1), content.toolbar[1].enabled.value);
    instance.task_id = 2;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[1].enabled.value);
    try std.testing.expectEqual(@as(u64, 1), instance.runtime_task_id);
}

test "library view bounds rows and uses stable IDs" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined };
    instance.library_loaded = true;
    instance.library_snapshot.count = 17;
    for (instance.library_snapshot.rows[0..17], 0..) |*row, n| {
        row.* = .{ .id = n + 1, .source = @splat('a'), .len = 1, .paired = true };
    }
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 23), content.root.children.count);
    try std.testing.expect(std.mem.startsWith(u8, abi.slice(content.children[7].id).?, "asset-1-"));
    instance.library_offset = 16;
    fill(instance, &content, &tree);
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
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .library_loaded = true };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 7), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 3), content.children[4].children.count);
    try std.testing.expectEqualStrings("library.empty", abi.slice(content.children[6].id).?);
    instance.library_snapshot.total = 1;
    fill(instance, &content, &tree);
    try std.testing.expectEqualStrings("library.no-match", abi.slice(content.children[6].id).?);
    instance.task_id = 1;
    fill(instance, &content, &tree);
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
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(ui.NodeKind.text_input, content.children[3].type);
    try std.testing.expectEqualStrings("library.query", abi.slice(content.children[3].state.value).?);
    try std.testing.expectEqualStrings("search", abi.slice(content.children[3].glyph.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.children[3].text.present);
    try std.testing.expectEqualStrings(commands[7], abi.slice(content.toolbar[0].command.value).?);
    try std.testing.expectEqualStrings(commands[28], abi.slice(content.toolbar[2].command.value).?);
}

test "typing copies latest user query without mutating the worker input" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .active = true, .page = 9, .search_token = 1, .task_id = 12 };
    rememberSearch(instance, "old");
    applySearch(instance);
    var change: raw.PulseUiStateChange = .{ .key = abi.view("library.query"), .value = abi.view("猫"), .revision = 2, .source_mask = @intCast(raw.PULSE_UI_STATE_USER) };
    var batch: raw.PulseUiStateBatch = .{ .revision = 2, .changes = &change, .count = 1 };
    onSearchChanged(instance, 9, &batch);
    try std.testing.expectEqualStrings("猫", instance.search_draft[0..instance.search_draft_len]);
    try std.testing.expectEqualStrings("old", instance.query[0..instance.query_len]);
    change.value = abi.view("wrong");
    change.revision = 3;
    change.source_mask = @intCast(raw.PULSE_UI_STATE_PROGRAMMATIC);
    onSearchChanged(instance, 9, &batch);
    try std.testing.expectEqualStrings("猫", instance.search_draft[0..instance.search_draft_len]);
    instance.task_id = 0;
    applySearch(instance);
    try std.testing.expectEqualStrings("猫", instance.query[0..instance.query_len]);
    try std.testing.expect(!validSearch("a\x00b"));
}

test "running search matches source and exact IDs without treating missing PID as zero" {
    const item: library.RunningRow = .{ .id = 12, .asset_id = 5, .metrics = .{ .pid = 345, .private_bytes = 0, .working_set = 0, .handles = 0 } };
    try std.testing.expect(runningMatches(item, "cat", "CAT 345"));
    try std.testing.expect(runningMatches(item, "cat", "#12"));
    try std.testing.expect(runningMatches(item, "cat", "5"));
    try std.testing.expect(!runningMatches(item, "cat", "34"));
    try std.testing.expect(!runningMatches(item, "cat", "dog"));
    const missing: library.RunningRow = .{ .id = 12, .asset_id = 5 };
    try std.testing.expect(!runningMatches(missing, "cat", "0"));
    try std.testing.expect(runningMatches(missing, "猫", "猫"));
}

test "market panel requires explicit admission and has no implicit install" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .section = .market };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 8), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 3), content.children[6].children.count);
    try std.testing.expectEqualStrings(commands[55], abi.slice(content.market_filter_actions[0].command.value).?);
    try std.testing.expectEqualStrings("market.query", abi.slice(content.children[3].id).?);
    try std.testing.expectEqual(@as(u32, 0), content.market_actions[0].enabled.value);
    try std.testing.expectEqual(@as(u32, 0), content.market_actions[1].enabled.value);
    try std.testing.expectEqual(@as(u32, 0), content.market_actions[2].enabled.value);
    try std.testing.expectEqualStrings(commands[39], abi.slice(content.market_actions[3].command.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.market_actions[3].enabled.value);
    try std.testing.expectEqualStrings(commands[78], abi.slice(content.market_actions[4].command.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.market_actions[4].enabled.value);
    try std.testing.expect(std.mem.indexOf(u8, abi.slice(content.children[5].text.value).?, library.market_gallery_url) != null);
    try std.testing.expectEqualStrings("search", abi.slice(content.children[3].glyph.value).?);
    try std.testing.expectEqual(@as(u32, 26), tree.state_count);
    try std.testing.expect(instance.market_selected == null);
}

test "running page bounds rendered controls at full storage capacity" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .section = .running, .runtime_task_id = 1, .task_kind = .builtin_session };
    instance.session.set(.running);
    instance.running_rows.count = library.session_limit;
    for (instance.running_rows.rows[0..library.session_limit], 0..) |*row, n| {
        row.* = .{ .id = n + 1, .asset_id = 1 };
    }
    instance.running_offset = 1019;
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(usize, 1020), runningPageStart(1024, library.session_limit));
    try std.testing.expectEqual(@as(u32, 23), content.root.children.count);
    instance.running_offset = 1024;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 15), content.root.children.count);
    try std.testing.expect(std.mem.startsWith(u8, abi.slice(content.children[9].id).?, "instance-3fd-"));
    instance.running_rows.count = 1;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 11), content.root.children.count);
}

test "persisted runtime limits reject malformed and duplicate settings" {
    var values = [_]raw.PulseSetting{ .{ .key = abi.view(runtime_preference), .value = abi.view("1024:256") }, .{ .key = abi.view(runtime_preference), .value = abi.view("8:1024") } };
    try std.testing.expectEqual(@as(usize, 8), (try readRuntimeLimits(.{})).effective());
    try std.testing.expectEqual(@as(usize, 2), (try readRuntimeLimits(.{ .values = &values, .count = 1 })).effective());
    try std.testing.expectError(error.InvalidSettings, readRuntimeLimits(.{ .values = &values, .count = 2 }));
    values[0].value = abi.view("1025:256");
    try std.testing.expectError(error.InvalidLimits, readRuntimeLimits(.{ .values = &values, .count = 1 }));
}

test "profile controls preserve disabled admission and explicit launch actions" {
    var content: Content = undefined;
    const node = fillProfileControls(&content, false, true);
    try std.testing.expectEqual(@as(u32, 5), node.children.count);
    for (content.profile_controls) |control| try std.testing.expectEqual(@as(u32, 0), control.enabled.value);
    try std.testing.expectEqualStrings(commands[75], abi.slice(content.profile_launch[1].command.value).?);
    try std.testing.expectEqual(@as(u32, 1), content.profile_launch[1].enabled.value);
}

test "verified local detail is copied into bounded native text nodes" {
    var detail: library.AssetDetail = .{ .version = 2, .activities = 3, .outfits = 4, .rules = 1, .name_len = 3, .description_len = 7 };
    @memcpy(detail.name[0..3], "Cat");
    @memcpy(detail.description[0..7], "Fixture");
    var content: Content = undefined;
    const node = fillLocalDetail(&content, 7, &detail);
    try std.testing.expectEqual(@as(u32, 4), node.children.count);
    try std.testing.expectEqualStrings("Fixture", abi.slice(content.local_detail_nodes[2].text.value).?);
}

test "preview 3 image diagnostic is opt-in and uses verified field mapping" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .section = .market };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 8), content.root.children.count);
    instance.market_image_test = true;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 10), content.root.children.count);
    try std.testing.expectEqualStrings(commands[79], abi.slice(content.children[9].command.value).?);
    const image = &content.children[8];
    try std.testing.expectEqual(@as(u32, 44), image.type);
    try std.testing.expectEqual(@as(u32, @sizeOf(ui.Node)), image.size);
    try std.testing.expectEqualStrings(preview3_fixture, abi.slice(image.glyph.value).?);
    try std.testing.expectEqualStrings("contain", abi.slice(image.kind.value).?);
    try std.testing.expectEqual(@as(i64, 64), image.min_height.value);
    try std.testing.expectEqual(@as(u32, 1), image.text.present);
    rejectMarketImage(instance);
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 8), content.root.children.count);
    try std.testing.expectEqual(@as(u32, 0), content.children[7].enabled.value);
    try std.testing.expectEqualStrings(commands[78], abi.slice(content.market_actions[4].command.value).?);
}

test "market browser and batch tasks retain manual collection without a dispatcher" {
    const instance = try std.testing.allocator.create(Instance);
    defer std.testing.allocator.destroy(instance);
    instance.* = .{ .host = undefined, .section = .market, .active = true, .task_id = 7, .market_browser_pending = true };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    try std.testing.expectEqual(@as(u32, 9), content.root.children.count);
    try std.testing.expectEqualStrings(commands[38], abi.slice(content.children[8].command.value).?);
    try std.testing.expectEqual(@as(u32, 0), content.market_actions[4].enabled.value);
    instance.market_image_test = true;
    onCommand(instance, instance.page, abi.view(commands[79]));
    try std.testing.expect(instance.market_image_rejected and !instance.market_image_test);
    onCommand(instance, instance.page, abi.view(commands[77]));
    try std.testing.expect(!instance.market_image_test);
}

test "runtime policy setting is opt-in and validated before publication" {
    var values = [_]raw.PulseSetting{ .{ .key = abi.view(policy_preference), .value = abi.view("1:2:500:2000:10000;builtin:2:0") }, .{ .key = abi.view(policy_preference), .value = abi.view("0:4:500:2000:10000") } };
    try std.testing.expect(!(try readRuntimePolicy(.{})).automatic);
    const policy = try readRuntimePolicy(.{ .values = &values, .count = 1 });
    try std.testing.expect(policy.automatic);
    try std.testing.expectEqual(@as(usize, 2), policy.total());
    try std.testing.expectError(error.InvalidSettings, readRuntimePolicy(.{ .values = &values, .count = 2 }));
}

test "native policy fields use canonical booleans and reject injected records" {
    var fields: [15][]const u8 = .{ "true", "2", "500", "2000", "10000", "builtin:2:0", "", "7:1:1", "", "", "", "", "", "true", "true" };
    const policy = try decodePolicyFields(&fields);
    try std.testing.expect(policy.automatic);
    try std.testing.expectEqual(@as(usize, 3), policy.total());
    var buffers: [15][64]u8 = undefined;
    var states: [15]ui.State = undefined;
    policyEditorStates(&policy, &buffers, &states);
    try std.testing.expectEqualStrings("true", abi.slice(states[0].value).?);
    try std.testing.expectEqualStrings("true", abi.slice(states[13].value).?);
    try std.testing.expect(policy.hide_on_minimize and policy.retain_history);
    try std.testing.expectEqualStrings("true", abi.slice(states[14].value).?);
    try std.testing.expectEqualStrings("7:1:1", abi.slice(states[6].value).?);
    fields[5] = "builtin:2:0;8:1:0";
    try std.testing.expectError(error.InvalidPolicy, decodePolicyFields(&fields));
    fields[5] = "builtin:2:0";
    fields[0] = "1";
    try std.testing.expectError(error.InvalidPolicy, decodePolicyFields(&fields));
    fields[0] = "false";
    fields[1] = "2:3";
    try std.testing.expectError(error.InvalidPolicy, decodePolicyFields(&fields));
    var content: Content = undefined;
    const editor = fillPolicyEditor(&content, false);
    try std.testing.expectEqual(@as(u32, 17), editor.children.count);
    try std.testing.expectEqual(ui.NodeKind.checkbox, content.policy_nodes[0].type);
    try std.testing.expectEqual(@as(u32, 0), content.policy_nodes[0].enabled.value);
}
