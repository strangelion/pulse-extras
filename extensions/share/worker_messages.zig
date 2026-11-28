const std = @import("std");

pub const Finding = struct { code: []const u8, message: []const u8 };

pub fn find(value: []const u8) ?Finding {
    const prefix = "Pulse Share: ";
    const error_text = if (std.mem.startsWith(u8, value, prefix)) value[prefix.len..] else value;
    const messages = [_]struct { code: []const u8, technical: []const u8, user: []const u8 }{
        .{ .code = "ENDPOINT", .technical = "peer must be a permitted numeric address and port", .user = "请输入可达的对端数字 IP 和端口，例如 192.168.1.21:45843。IPv6 请加方括号。跨网段时请选择组网连接。" },
        .{ .code = "PEER_LABEL", .technical = "invalid UTF-8 device label", .user = "设备名称可用中文、英文或数字，最多 48 个字符，请去掉路径符号或控制字符。" },
        .{ .code = "LOCAL_ADDRESS", .technical = "bind a concrete supported local interface address", .user = "本机地址无效，请在「设备」页选择正在使用的网络。" },
        .{ .code = "LOCAL_INTERFACE", .technical = "bind address not found on an active local interface", .user = "当前本机地址已不可用，请重新选择网络。" },
        .{ .code = "IPV6_SCOPE", .technical = "IPv6 link-local bind requires interface zone", .user = "请选择带网卡编号的 IPv6 本机地址，例如 fe80::1%12。" },
        .{ .code = "ROUTED_SOURCE", .technical = "routed receive requires one exact numeric source address", .user = "请填写允许连接的对端实际来源 IP，该字段无需端口。" },
        .{ .code = "PEER_EXISTS", .technical = "peer label already exists", .user = "已有同名配对记录，请改用新名称，或先撤销原记录。" },
        .{ .code = "DISCOVERY", .technical = "selected interface has no LAN multicast", .user = "当前网卡不支持局域网发现，可以手动填写地址。" },
        .{ .code = "PRIVATE_ROUTE", .technical = "dynamic pairing requires a private or overlay address", .user = "动态码组网配对需要私有地址或虚拟组网地址。" },
        .{ .code = "PUBLIC_ROUTE", .technical = "public dynamic pairing disabled", .user = "公网地址请使用完整证书指纹手动配对。" },
        .{ .code = "CLIPBOARD_PRIVATE", .technical = "clipboard item is marked private", .user = "剪贴板中的内容已标记为私密。配对码可以直接粘贴到聊天，Share 不会传输这项剪贴板内容。" },
        .{ .code = "DIRECTORY_PORT", .technical = "directory service requires a fixed port", .user = "只读目录服务需要固定监听端口。请在「设置」中展开存储位置和端口并填写端口。" },
        .{ .code = "DIRECTORY_SOURCE", .technical = "directory service requires one selected directory and saved peer", .user = "请先在发送页选择一个文件夹，再选择已配对设备。" },
        .{ .code = "DIRECTORY_SOURCE", .technical = "select a directory", .user = "请在发送页选择一个文件夹来开启只读目录服务。" },
        .{ .code = "CLIPBOARD_CHANGED", .technical = "local clipboard changed during transfer; refusing overwrite", .user = "检测到你修改了本机剪贴板，会话已结束以保留新内容。" },
        .{ .code = "CLIPBOARD_DECLINED", .technical = "clipboard sync declined", .user = "未批准自动剪贴板会话。" },
        .{ .code = "DIRECTORY_DECLINED", .technical = "directory service declined", .user = "未批准开启只读目录服务。" },
        .{ .code = "SPOOL_MISSING", .technical = "receive spool missing", .user = "私有暂存目录尚未创建。请在「设备」页点「初始化本机」，或在设置里更改位置。" },
        .{ .code = "STORE_UNINITIALIZED", .technical = "identity missing", .user = "本机身份尚未初始化。请在「设备」或「设置」页点击「初始化本机」。" },
        .{ .code = "STORE_UNINITIALIZED", .technical = "store not initialized", .user = "本机身份目录尚未初始化。请在「设备」或「设置」页点击「初始化本机」。" },
        .{ .code = "DESTINATION_EXISTS", .technical = "destination already exists", .user = "接收目录中已存在同名文件，已停止传输以避免覆盖。" },
        .{ .code = "DECLINED", .technical = "local user declined", .user = "已拒绝本次传输请求。" },
        .{ .code = "DECLINED", .technical = "peer declined", .user = "对端拒绝了本次传输请求。" },
        .{ .code = "DECLINED", .technical = "batch not approved", .user = "对端未批准本次批量传输。" },
        .{ .code = "PROMPT_TIMEOUT", .technical = "confirmation timed out", .user = "等待确认超时，本次任务已自动结束。" },
        .{ .code = "PAIR_CODE", .technical = "pairing code", .user = "配对连接码不匹配或已轮换过期，请核对最新的 8 位连接码。" },
    };
    for (messages) |message| {
        if (std.mem.startsWith(u8, error_text, message.technical)) return .{ .code = message.code, .message = message.user };
    }
    if (std.mem.indexOf(u8, error_text, "no application protocol") != null or std.mem.indexOf(u8, error_text, "application protocol") != null or std.mem.indexOf(u8, error_text, "ALPN") != null)
        return .{ .code = "PROTOCOL_MISMATCH", .message = "收发模式不匹配：发送单文件请点「接收单文件」，发送文件夹或多个文件请点「接收文件夹 / 多文件」，QUIC 需双方一致。" };
    if (std.mem.indexOf(u8, error_text, "connection refused") != null or std.mem.indexOf(u8, error_text, "actively refused") != null)
        return .{ .code = "CONNECTION_REFUSED", .message = "无法连接到对端：请确认对端已开启接收或配对，且端口未被防火墙拦截。" };
    if (std.mem.indexOf(u8, error_text, "already exists") != null or std.mem.indexOf(u8, error_text, "file exists") != null)
        return .{ .code = "DESTINATION_EXISTS", .message = "接收目录中已存在同名文件，未覆盖原文件。" };
    if (std.mem.indexOf(u8, error_text, "pake") != null or std.mem.indexOf(u8, error_text, "wrong code") != null or std.mem.indexOf(u8, error_text, "confirmation mismatch") != null)
        return .{ .code = "PAIR_CODE", .message = "配对连接码不匹配或已过期，请核对最新的 8 位连接码。" };
    if (std.mem.indexOf(u8, error_text, "i/o timeout") != null or std.mem.indexOf(u8, error_text, "deadline exceeded") != null)
        return .{ .code = "TIMEOUT", .message = "连接超时。请检查两台设备的网络、端口及接收是否仍在运行。" };
    if (std.mem.indexOf(u8, error_text, "fp mismatch") != null or std.mem.indexOf(u8, error_text, "certificate pin mismatch") != null)
        return .{ .code = "IDENTITY_MISMATCH", .message = "证书指纹与配对记录不同，请通过可信渠道重新核对对端。" };
    if (std.mem.startsWith(u8, error_text, "Image") or std.mem.eql(u8, error_text, "Unconfigured"))
        return .{ .code = "WORKER_IMAGE", .message = "随包工作进程校验失败。请用同一版本的完整测试包重新安装。" };
    if (std.mem.eql(u8, error_text, "CancelUncertain"))
        return .{ .code = "CANCEL_UNCERTAIN", .message = "操作已中止，但提交结果未确认。请先检查接收目录和暂存状态。" };
    return null;
}

pub fn localize(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "CLIPBOARD SYNC active; cancel to stop")) return "自动剪贴板已连接，可随时停止。";
    if (std.mem.eql(u8, value, "DIRECTORY session complete; service remains active")) return "本次目录访问已完成，服务仍在运行。";
    if (std.mem.eql(u8, value, "DIRECTORY session ended; retrying listener")) return "目录会话已结束，正在重新等待连接。";
    return if (find(value)) |finding| finding.message else value;
}

test "explain endpoint errors and retain unexpected diagnostic information" {
    try std.testing.expect(std.mem.startsWith(u8, localize("Pulse Share: peer must be a permitted numeric address and port"), "请输入"));
    try std.testing.expect(std.mem.startsWith(u8, localize("tls: no application protocol"), "收发模式不匹配"));
    try std.testing.expect(std.mem.startsWith(u8, localize("dial tcp 192.168.1.2:45843: connectex: connection refused"), "无法连接到对端"));
    try std.testing.expect(std.mem.startsWith(u8, localize("Pulse Share: destination already exists"), "接收目录中已存在同名文件"));
    try std.testing.expectEqualStrings("Pulse Share: unexpected error", localize("Pulse Share: unexpected error"));
}
