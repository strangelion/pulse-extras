//! Experimental native Companion settings contribution. All SDK calls
//! are on the UI thread. Read-only inventory I/O uses a host task.
const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const ui = @import("pulse_ui_model");
const mount = @import("pulse_ui_mount");
const diag = @import("pulse_diagnostics");
const library = @import("companion_library");
const config = @import("companion_config");
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
const TaskKind = enum { library, runtime_check };
const names = [_][]const u8{ "素材库", "运行管理", "在线市场", "全局设置" };
const commands = [_][]const u8{ "companion.library", "companion.running", "companion.market", "companion.global", "companion.settings.refresh", "companion.download.less", "companion.download.more", "companion.library.reload", "companion.library.poll", "companion.library.previous", "companion.library.next", "companion.library.favorites" };

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
    task_kind: TaskKind = .library,
    runtime_status: []const u8 = if (config.runtime_sha256.len == 0) "未打包运行时；无法启动桌宠" else "切换至运行管理时检查同包运行时",
    runtime_checked: bool = false,
    task_state: u32 = raw.PULSE_TASK_RUNNING,
    work_done: std.atomic.Value(bool) = .init(false),
    work_error: ?anyerror = null,
    work_snapshot: library.Snapshot = .{},
    library_snapshot: library.Snapshot = .{},
    library_loaded: bool = false,
    library_status: []const u8 = "准备读取本地素材清单",
    library_offset: usize = 0,
    query: [256]u8 = undefined,
    query_len: usize = 0,
    favorites_only: bool = false,
    status: []const u8 = "设置尚未读取",
};

const Content = struct {
    declared: [commands.len]abi.StringView = undefined,
    navigation: [4]ui.Node = undefined,
    children: [24]ui.Node = undefined,
    toolbar: [4]ui.Node = undefined,
    paging: [2]ui.Node = undefined,
    states: [1]ui.State = undefined,
    row_text: [16][256]u8 = undefined,
    row_ids: [16][64]u8 = undefined,
    dynamic_ids: [4][64]u8 = undefined,
    library_count: [160]u8 = undefined,
    root: ui.Node = undefined,
    value: [128]u8 = undefined,
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
            content.children[3] = label("library.search-label", "搜索素材来源 ID 或标签");
            content.children[3].role = .{ .present = 1, .value = abi.view("caption") };
            content.toolbar[0] = ui.node(ui.NodeKind.text_input);
            content.toolbar[0].id = abi.view("library.query");
            content.toolbar[0].text = .{ .present = 1, .value = abi.view("搜索素材来源 ID 或标签") };
            content.toolbar[0].placeholder = .{ .present = 1, .value = abi.view("输入 ID 或标签") };
            content.toolbar[0].state = .{ .present = 1, .value = abi.view("library.query") };
            content.toolbar[1] = action("library.reload", "搜索 / 刷新", commands[7], instance.tasks != null and instance.task_id == 0);
            content.toolbar[2] = action(if (instance.favorites_only) "library.favorites.on" else "library.favorites.off", if (instance.favorites_only) "仅收藏：开" else "仅收藏：关", commands[11], instance.tasks != null and instance.task_id == 0);
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
                    content.children[count] = if (snapshot.total == 0) label("library.empty", "暂无本地素材；导入功能尚未接入。") else label("library.no-match", "没有匹配的素材，请调整搜索条件。");
                    count += 1;
                }
                if (snapshot.count > 16) {
                    content.paging[0] = action("library.previous", "上一页", commands[9], instance.library_offset > 0);
                    content.paging[1] = action("library.next", "下一页", commands[10], end < snapshot.count);
                    content.children[count] = horizontal("library.pagination", &content.paging);
                    count += 1;
                }
                for (snapshot.rows[instance.library_offset..end], 0..) |*row, n| {
                    const body = std.fmt.bufPrint(&content.row_text[n], "#{d}  {s} · {s} · {s} · 标签 {d} {s}", .{ row.id, row.sourceId(), if (row.paired) "双摘要记录" else "待重验", if (row.favorite) "已收藏" else "未收藏", row.tag_count, row.first_tag[0..row.first_tag_len] }) catch unreachable;
                    const id = std.fmt.bufPrint(&content.row_ids[n], "asset-{x}-{x}", .{ row.id, std.hash.Wyhash.hash(0, body) }) catch unreachable;
                    content.children[count] = label(id, body);
                    count += 1;
                }
            }
        },
        .running => content.children[2] = changingLabel(&content.dynamic_ids[0], "running.status", instance.runtime_status),
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
    content.states[0] = .{ .key = abi.view("library.query"), .value = abi.view(instance.query[0..instance.query_len]) };
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
    defer instance.work_done.store(true, .release);
    if (context == null) return raw.PULSE_TASK_FAILED;
    const canceled = context[0].cancelled orelse return raw.PULSE_TASK_FAILED;
    if (canceled(context[0].context) != 0) return raw.PULSE_TASK_CANCELLED;
    library.checkRuntime(config.runtime_sha256) catch |err| {
        instance.work_error = err;
        return raw.PULSE_TASK_FAILED;
    };
    return if (canceled(context[0].context) != 0) raw.PULSE_TASK_CANCELLED else raw.PULSE_TASK_COMPLETED;
}

fn observe(user: ?*anyopaque, snapshot: [*c]const raw.PulseTaskSnapshot) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (snapshot == null or snapshot[0].size < @sizeOf(raw.PulseTaskSnapshot) or snapshot[0].id != instance.task_id) return;
    instance.task_state = snapshot[0].state;
}

fn dispatchPoll(user: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    instance.queued.store(false, .release);
    if (instance.active) pollLibrary(instance);
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

fn pollLibrary(instance: *Instance) void {
    const tasks = instance.tasks orelse return;
    if (instance.task_id == 0) return;
    const get = tasks.get orelse return;
    const release = tasks.release orelse return;
    instance.task_state = raw.PULSE_TASK_RUNNING;
    if (get(tasks.context, instance.task_id, observe, instance) != abi.ok) {
        if (instance.task_kind == .runtime_check) {
            instance.runtime_status = "无法读取运行时任务状态；保留任务所有权";
        } else {
            instance.library_status = "无法读取任务状态；保留任务所有权";
        }
        refresh(instance);
        return;
    }
    if (instance.task_state == raw.PULSE_TASK_RUNNING or instance.task_state == raw.PULSE_TASK_CANCELLING) {
        return;
    }
    if (instance.task_state != raw.PULSE_TASK_COMPLETED and instance.task_state != raw.PULSE_TASK_FAILED and instance.task_state != raw.PULSE_TASK_CANCELLED and instance.task_state != raw.PULSE_TASK_PARTIAL) return;
    if (release(tasks.context, instance.task_id) != abi.ok) {
        if (instance.task_kind == .runtime_check) {
            instance.runtime_status = "运行时任务释放失败；请重试";
        } else {
            instance.library_status = "任务释放失败；请重试";
        }
        refresh(instance);
        return;
    }
    stopTimer(instance);
    diag.status("companion-library-terminal", instance.task_state);
    instance.task_id = 0;
    const done = instance.work_done.load(.acquire);
    if (instance.task_kind == .runtime_check) {
        instance.runtime_checked = instance.task_state == raw.PULSE_TASK_COMPLETED and done and instance.work_error == null;
        instance.runtime_status = if (instance.runtime_checked) "同包运行时已通过加载及关闭检查；实例启动尚未接入" else if (done) if (instance.work_error) |err| @errorName(err) else "运行时检查未完成" else "运行时检查已取消";
        refresh(instance);
        if (instance.section == .library and !instance.library_loaded) startLibrary(instance, false);
        return;
    }
    if (instance.task_state == raw.PULSE_TASK_COMPLETED and done and instance.work_error == null) {
        instance.library_snapshot = instance.work_snapshot;
        instance.library_loaded = true;
        instance.library_offset = 0;
        instance.library_status = if (instance.library_snapshot.missing) "固定目录中尚无素材清单（未创建文件）" else "已读取持久化清单；尚未验证素材文件";
    } else {
        instance.library_loaded = false;
        instance.library_status = if (instance.task_state == raw.PULSE_TASK_CANCELLED) "读取已取消" else if (done) if (instance.work_error) |err| @errorName(err) else "读取结果无效" else "读取未完成";
    }
    refresh(instance);
    if (instance.section == .running) startRuntimeCheck(instance);
}

fn startRuntimeCheck(instance: *Instance) void {
    if (!instance.active or config.runtime_sha256.len == 0 or instance.runtime_checked or instance.task_id != 0) return;
    const tasks = instance.tasks orelse return;
    const create = tasks.create orelse return;
    // Existing dispatcher/timer is required: do not create an uncollectable task.
    if (instance.dispatch == null) {
        instance.runtime_status = "宿主自动刷新不可用；未启动运行时检查";
        return;
    }
    instance.work_done.store(false, .release);
    instance.work_error = null;
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
        instance.task_id = id;
        instance.runtime_status = "正在验证并打开同包运行时";
        armTimer(instance);
        if (instance.timer == null) instance.runtime_status = "自动收集不可用；切换页面重试检查";
    } else {
        instance.runtime_status = "宿主拒绝运行时检查任务";
    }
    refresh(instance);
}

fn startLibrary(instance: *Instance, capture_query: bool) void {
    const tasks = instance.tasks orelse return;
    if (instance.task_id != 0) return;
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
        if (get_state(panel.table.context, panel.id, abi.view("library.query"), &buffer, buffer.len, &needed) != abi.ok or needed > instance.query.len or !std.unicode.utf8ValidateSlice(buffer[0..needed])) {
            instance.library_status = "搜索词无效或超过 256 字节";
            refresh(instance);
            return;
        }
        @memcpy(instance.query[0..needed], buffer[0..needed]);
        instance.query_len = needed;
    }
    instance.work_done.store(false, .release);
    instance.work_error = null;
    instance.work_snapshot = .{};
    instance.task_kind = .library;
    instance.library_loaded = false;
    const descriptor: raw.PulseTaskDescriptor = .{
        .size = @sizeOf(raw.PulseTaskDescriptor),
        .title = abi.view("读取桌宠素材清单"),
        .type = abi.view("companion.library"),
        .work = readLibrary,
        .user = instance,
    };
    var id: u64 = 0;
    if (create(tasks.context, &descriptor, &id) == abi.ok and id != 0) {
        instance.task_id = id;
        instance.library_status = "正在自动读取素材清单";
        armTimer(instance);
        if (instance.timer == null) instance.library_status = "正在读取；宿主自动刷新不可用，可手动检查";
    } else {
        instance.library_status = "宿主拒绝读取任务";
    }
    refresh(instance);
}

fn onCommand(user: ?*anyopaque, panel: u64, command: abi.StringView) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!instance.active or panel != instance.page) return;
    const name = abi.slice(command) orelse return;
    for (commands, 0..) |candidate, n| {
        if (!std.mem.eql(u8, candidate, name)) continue;
        if (n >= 4 and n <= 6 and instance.section != .global) return;
        if (n >= 7 and instance.section != .library) return;
        switch (n) {
            0, 1, 2, 3 => {
                instance.section = @fromBackingInt(@intCast(n));
                if (instance.task_id != 0 and instance.timer == null) pollLibrary(instance);
                if (instance.section == .library and !instance.library_loaded and instance.task_id == 0) startLibrary(instance, false);
                if (instance.section == .running) startRuntimeCheck(instance);
                refresh(instance);
            },
            4 => load(instance),
            5 => if (instance.saved > 1) save(instance, instance.saved - 1),
            6 => if (instance.saved < 8) save(instance, instance.saved + 1),
            7 => startLibrary(instance, true),
            8 => pollLibrary(instance),
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
            else => {},
        }
        return;
    }
}

fn close(instance: *Instance) host_mod.Error!void {
    instance.active = false;
    instance.runtime_checked = false;
    stopTimer(instance);
    if (instance.task_id != 0) {
        const tasks = instance.tasks orelse return error.State;
        const cancel = tasks.cancel orelse return error.Unavailable;
        host_mod.mapStatus(cancel(tasks.context, instance.task_id)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
    }
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
    if (instance.task_id == 0) {
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
    instance.active = true;
    if (instance.task_id != 0) {
        pollLibrary(instance);
        if (instance.task_id != 0) armTimer(instance);
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
        try std.testing.expectEqual(@as(u32, if (instance.section == .global or instance.section == .library) 5 else 3), content.root.children.count);
    }
    try std.testing.expectEqual(@as(u32, 0), content.toolbar[2].enabled.value);
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
