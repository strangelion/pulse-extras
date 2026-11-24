//! UTF-8-safe copying helpers for borrowed host strings.
//!
//! Host strings arrive as borrowed `PulseStringView` values and plugins usually
//! keep a bounded copy. Cutting at `buffer.len` can split a multi-byte
//! codepoint, so every copy here stops on a codepoint boundary instead.

const std = @import("std");

/// Copies `source` into `buffer`, truncating at the last complete codepoint
/// that fits. Returns the written slice (never longer than `buffer`).
pub fn copyTruncated(buffer: []u8, source: []const u8) []const u8 {
    if (source.len <= buffer.len) {
        @memcpy(buffer[0..source.len], source);
        return buffer[0..source.len];
    }
    var take = buffer.len;
    // Stop before a continuation byte, i.e. keep whole codepoints only.
    while (take > 0 and (source[take] & 0xC0) == 0x80) take -= 1;
    @memcpy(buffer[0..take], source[0..take]);
    return buffer[0..take];
}

/// Writes `prefix` followed by `value`, truncating `value` on a codepoint
/// boundary when the buffer is too small. The prefix itself may also be cut.
pub fn appendTruncated(buffer: []u8, prefix: []const u8, value: []const u8) []const u8 {
    if (prefix.len >= buffer.len) return copyTruncated(buffer, prefix);
    @memcpy(buffer[0..prefix.len], prefix);
    const rest = copyTruncated(buffer[prefix.len..], value);
    return buffer[0 .. prefix.len + rest.len];
}

const testing = std.testing;

test "copyTruncated keeps ASCII and complete codepoints" {
    var buffer: [8]u8 = undefined;
    // "目录：" is 9 bytes; 8 bytes must drop the last character, not half of it.
    const line = copyTruncated(&buffer, "目录：");
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expectEqualStrings("目录", line);

    var exact: [3]u8 = undefined;
    try testing.expectEqualStrings("目", copyTruncated(&exact, "目"));
}

test "copyTruncated never splits a four-byte emoji" {
    var buffer: [5]u8 = undefined;
    const emoji = "🙂🙂"; // 4 + 4 bytes
    const line = copyTruncated(&buffer, emoji);
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expectEqualStrings("🙂", line);
}

test "appendTruncated respects the prefix" {
    var buffer: [16]u8 = undefined;
    const line = appendTruncated(&buffer, "选中：", "中文文件名😀.txt");
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expect(std.mem.startsWith(u8, line, "选中："));
    try testing.expect(line.len <= buffer.len);
}

test "copyTruncated handles a long path and an empty view" {
    const long = "C:\\Users\\用户\\Documents\\GitHub\\pulse-extras\\.local\\very\\long\\path\\文件.txt";
    var buffer: [32]u8 = undefined;
    const line = copyTruncated(&buffer, long);
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expectEqual(@as(usize, 32), line.len);

    var empty: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), copyTruncated(&empty, "").len);
}
