//! Bounded persistent market JSON cache record. No filesystem or clock
//! dependency. Exact URL/revision is stored; a slot collision is a miss,
//! never a different response. SHA-256 detects corruption, not authenticity.
const std = @import("std");
const market = @import("pet_market.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const slots = 32;
pub const header_size = 52;
pub const max_record = market.max_response_bytes + header_size + 64 + 2048;
pub const max_disk_bytes = (slots + 1) * max_record;
pub const max_stale_seconds = 7 * 24 * 60 * 60;

pub const Key = struct {
    revision: []const u8,
    url: []const u8,

    pub fn valid(self: Key) bool {
        if (std.mem.eql(u8, self.url, market.index_url)) return self.revision.len == 0;
        if (self.revision.len == 0 or self.revision.len > 64 or !std.unicode.utf8ValidateSlice(self.revision)) return false;
        for (self.revision) |ch| {
            if (ch < 32 or ch == 127) return false;
        }
        return market.validUrl(self.url, .catalog);
    }

    pub fn slot(self: Key) u32 {
        if (std.mem.eql(u8, self.url, market.index_url)) return 0;
        var hash = Sha256.init(.{});
        hash.update(self.revision);
        hash.update(&.{0});
        hash.update(self.url);
        const digest = hash.finalResult();
        return 1 + @as(u32, digest[0]) % (slots - 1);
    }
};

fn put(out: []u8, value: u64) void {
    for (out, 0..) |*byte, n| byte.* = @truncate(value >> @as(u6, @intCast(n * 8)));
}

fn get(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |byte, n| value |= @as(u64, byte) << @as(u6, @intCast(n * 8));
    return value;
}

fn checksum(record: []const u8) [32]u8 {
    var hash = Sha256.init(.{});
    hash.update(record[0..20]);
    hash.update(record[header_size..]);
    return hash.finalResult();
}

pub fn encode(out: []u8, key: Key, now: u64, payload: []const u8) ![]const u8 {
    if (!key.valid() or now == 0 or payload.len == 0 or payload.len > market.max_response_bytes) return error.InvalidRecord;
    const len = header_size + key.revision.len + key.url.len + payload.len;
    if (out.len < len) return error.BufferTooSmall;
    const record = out[0..len];
    @memcpy(record[0..4], "PMC1");
    put(record[4..12], now);
    put(record[12..14], key.revision.len);
    put(record[14..16], key.url.len);
    put(record[16..20], payload.len);
    @memcpy(record[header_size..][0..key.revision.len], key.revision);
    @memcpy(record[header_size + key.revision.len ..][0..key.url.len], key.url);
    @memcpy(record[header_size + key.revision.len + key.url.len ..], payload);
    const digest = checksum(record);
    @memcpy(record[20..52], &digest);
    return record;
}

pub const Entry = struct {
    payload: []const u8,
    stored_at: u64,
    stale: bool,
};

/// A stale entry is returned only by explicit offline policy. A future
/// timestamp or an older-than-seven-days record is always a miss.
pub fn decode(record: []const u8, expected: Key, now: u64, offline: bool) !?Entry {
    if (!expected.valid()) return error.InvalidRecord;
    if (record.len < header_size or record.len > max_record or !std.mem.eql(u8, record[0..4], "PMC1")) return error.InvalidRecord;
    const revision_len: usize = @intCast(get(record[12..14]));
    const url_len: usize = @intCast(get(record[14..16]));
    const payload_len: usize = @intCast(get(record[16..20]));
    if (revision_len > 64 or url_len > 2048 or payload_len == 0 or payload_len > market.max_response_bytes or
        record.len != header_size + revision_len + url_len + payload_len) return error.InvalidRecord;
    const key: Key = .{
        .revision = record[header_size..][0..revision_len],
        .url = record[header_size + revision_len ..][0..url_len],
    };
    if (!key.valid()) return error.InvalidRecord;
    const digest = checksum(record);
    if (!std.mem.eql(u8, record[20..52], &digest)) return error.InvalidRecord;
    if (!std.mem.eql(u8, key.revision, expected.revision) or !std.mem.eql(u8, key.url, expected.url)) return null;
    const stored = get(record[4..12]);
    if (stored == 0 or now < stored or now - stored > max_stale_seconds) return null;
    const ttl: u64 = if (key.revision.len == 0) 15 * 60 else 24 * 60 * 60;
    const stale = now - stored >= ttl;
    if (stale and !offline) return null;
    return .{ .payload = record[header_size + revision_len + url_len ..], .stored_at = stored, .stale = stale };
}

test "cache exact key, TTL, offline ceiling and digest validation" {
    var bytes: [256]u8 = undefined;
    const key: Key = .{ .revision = "", .url = market.index_url };
    const data = try encode(&bytes, key, 1000, "{}");
    try std.testing.expectEqual(@as(u32, 0), key.slot());
    try std.testing.expectEqualStrings("{}", (try decode(data, key, 1001, false)).?.payload);
    try std.testing.expect((try decode(data, key, 1900, false)) == null);
    try std.testing.expect((try decode(data, key, 1900, true)).?.stale);
    try std.testing.expect((try decode(data, key, 999, true)) == null);
    try std.testing.expect((try decode(data, key, 1000 + max_stale_seconds + 1, true)) == null);
    const page: Key = .{ .revision = "revision-a", .url = "https://openpets.dev/pets/catalog.v3/page.json" };
    const page_data = try encode(&bytes, page, 1000, "{}");
    var other = page;
    other.revision = "revision-b";
    try std.testing.expect((try decode(page_data, other, 1001, true)) == null);
    try std.testing.expect(page.slot() > 0 and page.slot() < slots);
    bytes[page_data.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidRecord, decode(page_data, page, 1001, false));
}
