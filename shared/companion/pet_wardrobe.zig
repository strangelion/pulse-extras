//! Pure, bounded wardrobe contract from the pinned OpenPets wardrobe.ts.
//! Local civil time is supplied by the caller; no timers, I/O or rendering.
const std = @import("std");
const activities = @import("pet_activities.zig");

pub const max_outfits = activities.max_outfits;
pub const max_rules = 32;
pub const Error = error{InvalidWardrobe};
pub const Format = enum { webp, svg };

pub const Outfit = struct {
    id: activities.Id = .{},
    name: [160]u8 = @splat(0),
    name_len: u8 = 0,
    format: Format = .webp,

    pub fn displayName(self: *const Outfit) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn path(self: *const Outfit, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        return std.fmt.bufPrint(buffer, "outfits/{s}.{s}", .{ self.id.slice(), @tagName(self.format) });
    }
};

const Range = struct { from: u16, to: u16 };
pub const Moment = struct {
    minute: u16,
    weekday: u8, // Sunday = 0
    month: u8,
    day: u8,

    fn valid(self: Moment) bool {
        return self.minute < 1440 and self.weekday < 7 and validDate(self.month, self.day);
    }
};

pub const Rule = struct {
    outfit: u8 = 0, // default = 0, declared outfits = index + 1
    enabled: bool = true,
    time: ?Range = null,
    days: ?u8 = null,
    dates: ?Range = null,

    pub fn matches(self: Rule, now: Moment) bool {
        if (!self.enabled or !now.valid()) return false;
        if (self.days) |mask| {
            if (mask & (@as(u8, 1) << @as(u3, @intCast(now.weekday))) == 0) return false;
        }
        if (self.time) |r| {
            const inside = if (r.from < r.to) now.minute >= r.from and now.minute < r.to else now.minute >= r.from or now.minute < r.to;
            if (!inside) return false;
        }
        if (self.dates) |r| {
            const date = @as(u16, now.month) * 100 + now.day;
            const inside = if (r.from <= r.to) date >= r.from and date <= r.to else date >= r.from or date <= r.to;
            if (!inside) return false;
        }
        return self.days != null or self.time != null or self.dates != null;
    }
};

pub const Wardrobe = struct {
    outfits: [max_outfits]Outfit = @splat(.{}),
    count: u8 = 0,
    rules: [max_rules]Rule = @splat(.{}),
    rule_count: u8 = 0,

    pub fn indexOf(self: *const Wardrobe, id: []const u8) ?u8 {
        if (std.mem.eql(u8, id, "default")) return 0;
        for (self.outfits[0..self.count], 0..) |*outfit, i| {
            if (std.mem.eql(u8, id, outfit.id.slice())) return @intCast(i + 1);
        }
        return null;
    }

    /// Fixed choice wins if known; unknown choices follow the creator
    /// schedule. First enabled matching rule wins, otherwise default.
    /// User-edited replacement schedules are a future preference layer.
    pub fn resolve(self: *const Wardrobe, fixed: ?[]const u8, now: Moment) u8 {
        if (fixed) |id| {
            if (self.indexOf(id)) |index| return index;
        }
        for (self.rules[0..self.rule_count]) |rule| {
            if (rule.outfit <= self.count and rule.matches(now)) return rule.outfit;
        }
        return 0;
    }

    pub fn copyIds(self: *const Wardrobe, out: *[max_outfits]activities.Id) []const activities.Id {
        for (self.outfits[0..self.count], 0..) |outfit, i| out[i] = outfit.id;
        return out[0..self.count];
    }
};

fn string(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidWardrobe;
}

fn pair(s: []const u8, sep: u8) Error!struct { a: u16, b: u16 } {
    if (s.len != 5 or s[2] != sep) return error.InvalidWardrobe;
    for ([_]usize{ 0, 1, 3, 4 }) |i| {
        if (!std.ascii.isDigit(s[i])) return error.InvalidWardrobe;
    }
    return .{
        .a = @as(u16, s[0] - '0') * 10 + (s[1] - '0'),
        .b = @as(u16, s[3] - '0') * 10 + (s[4] - '0'),
    };
}

fn clock(value: std.json.Value) Error!u16 {
    const p = try pair(try string(value), ':');
    if (p.a >= 24 or p.b >= 60) return error.InvalidWardrobe;
    return p.a * 60 + p.b;
}

fn validDate(month: u16, day: u16) bool {
    const lengths = [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return month >= 1 and month <= 12 and day >= 1 and day <= lengths[month - 1];
}

fn monthDay(value: std.json.Value) Error!u16 {
    const p = try pair(try string(value), '-');
    if (!validDate(p.a, p.b)) return error.InvalidWardrobe;
    return p.a * 100 + p.b;
}

fn range(value: std.json.Value, is_time: bool) Error!Range {
    if (value != .object) return error.InvalidWardrobe;
    const from = value.object.get("from") orelse return error.InvalidWardrobe;
    const to = value.object.get("to") orelse return error.InvalidWardrobe;
    const r: Range = if (is_time)
        .{ .from = try clock(from), .to = try clock(to) }
    else
        .{ .from = try monthDay(from), .to = try monthDay(to) };
    if (is_time and r.from == r.to) return error.InvalidWardrobe;
    return r;
}

fn parseDays(value: std.json.Value) Error!u8 {
    if (value != .array or value.array.items.len == 0) return error.InvalidWardrobe;
    const days = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
    var mask: u8 = 0;
    for (value.array.items) |day| {
        const name = try string(day);
        var found = false;
        for (days, 0..) |known, i| {
            if (std.mem.eql(u8, name, known)) {
                mask |= @as(u8, 1) << @as(u3, @intCast(i));
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidWardrobe;
    }
    return mask;
}

fn parseRule(value: std.json.Value, wardrobe: *const Wardrobe) Error!Rule {
    if (value != .object) return error.InvalidWardrobe;
    const obj = value.object;
    const id = try string(obj.get("outfit") orelse return error.InvalidWardrobe);
    var rule: Rule = .{ .outfit = wardrobe.indexOf(id) orelse return error.InvalidWardrobe };
    if (obj.get("enabled")) |enabled| {
        if (enabled != .bool) return error.InvalidWardrobe;
        rule.enabled = enabled.bool;
    }
    const when = obj.get("when") orelse return error.InvalidWardrobe;
    if (when != .object) return error.InvalidWardrobe;
    if (when.object.get("time")) |v| rule.time = try range(v, true);
    if (when.object.get("days")) |v| rule.days = try parseDays(v);
    if (when.object.get("dates")) |v| rule.dates = try range(v, false);
    if (rule.time == null and rule.days == null and rule.dates == null) return error.InvalidWardrobe;
    return rule;
}

pub fn parse(value: ?std.json.Value) Error!Wardrobe {
    var result: Wardrobe = .{};
    const data = value orelse return result;
    if (data != .object) return error.InvalidWardrobe;
    const outfits = data.object.get("outfits") orelse return error.InvalidWardrobe;
    if (outfits != .array or outfits.array.items.len == 0 or outfits.array.items.len > max_outfits) return error.InvalidWardrobe;
    for (outfits.array.items) |entry| {
        if (entry != .object) return error.InvalidWardrobe;
        const obj = entry.object;
        const id = activities.Id.parse(try string(obj.get("id") orelse return error.InvalidWardrobe)) catch return error.InvalidWardrobe;
        if (result.indexOf(id.slice()) != null or std.mem.eql(u8, id.slice(), "auto")) return error.InvalidWardrobe;
        const name = activities.checkedText(obj.get("displayName") orelse return error.InvalidWardrobe, 40) orelse return error.InvalidWardrobe;
        const path = try string(obj.get("spritesheetPath") orelse return error.InvalidWardrobe);
        var outfit: Outfit = .{ .id = id, .name_len = @intCast(name.len), .format = if (std.mem.endsWith(u8, path, ".svg")) .svg else .webp };
        @memcpy(outfit.name[0..name.len], name);
        var buffer: [64]u8 = undefined;
        if (!std.mem.eql(u8, path, outfit.path(&buffer) catch unreachable)) return error.InvalidWardrobe;
        result.outfits[result.count] = outfit;
        result.count += 1;
    }
    if (data.object.get("schedule")) |schedule| {
        if (schedule != .array or schedule.array.items.len > max_rules) return error.InvalidWardrobe;
        for (schedule.array.items) |entry| {
            result.rules[result.rule_count] = try parseRule(entry, &result);
            result.rule_count += 1;
        }
    }
    return result;
}

const t = std.testing;
const fixture_outfits = "{\"outfits\":[{\"id\":\"night\",\"displayName\":\"睡衣\",\"spritesheetPath\":\"outfits/night.webp\"},{\"id\":\"winter\",\"displayName\":\"Winter\",\"spritesheetPath\":\"outfits/winter.svg\"}]";

fn fixture(input: []const u8) !Wardrobe {
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, input, .{});
    defer parsed.deinit();
    return parse(parsed.value);
}

test "ordered rules wrap midnight and year with independent weekdays" {
    const w = try fixture(fixture_outfits ++ ",\"schedule\":[{\"outfit\":\"winter\",\"when\":{\"dates\":{\"from\":\"12-20\",\"to\":\"01-02\"}}},{\"outfit\":\"night\",\"when\":{\"days\":[\"fri\"],\"time\":{\"from\":\"22:00\",\"to\":\"07:00\"}}}]}");
    try t.expectEqualStrings("睡衣", w.outfits[0].displayName());
    try t.expectEqual(Format.svg, w.outfits[1].format);
    try t.expectEqual(@as(u8, 2), w.resolve(null, .{ .minute = 1380, .weekday = 5, .month = 12, .day = 25 }));
    try t.expectEqual(@as(u8, 1), w.resolve(null, .{ .minute = 1320, .weekday = 5, .month = 11, .day = 20 }));
    try t.expectEqual(@as(u8, 0), w.resolve(null, .{ .minute = 120, .weekday = 6, .month = 11, .day = 21 }));
    try t.expectEqual(@as(u8, 0), w.resolve(null, .{ .minute = 420, .weekday = 5, .month = 11, .day = 20 }));
    try t.expectEqual(@as(u8, 0), w.resolve("default", .{ .minute = 1380, .weekday = 5, .month = 12, .day = 25 }));
    try t.expectEqual(@as(u8, 2), w.resolve("removed", .{ .minute = 0, .weekday = 0, .month = 1, .day = 2 }));
}

test "disabled rules, leap day and default fallbacks" {
    const w = try fixture(fixture_outfits ++ ",\"schedule\":[{\"outfit\":\"winter\",\"enabled\":false,\"when\":{\"days\":[\"thu\"]}},{\"outfit\":\"night\",\"when\":{\"dates\":{\"from\":\"02-29\",\"to\":\"02-29\"}}}]}");
    try t.expectEqual(@as(u8, 1), w.resolve(null, .{ .minute = 0, .weekday = 4, .month = 2, .day = 29 }));
    try t.expectEqual(@as(u8, 0), w.resolve(null, .{ .minute = 0, .weekday = 4, .month = 3, .day = 1 }));
    try t.expectEqual(@as(u8, 2), w.resolve("winter", .{ .minute = 0, .weekday = 4, .month = 3, .day = 1 }));
}

test "reject reserved ids invalid dates paths and unknown rule targets" {
    try t.expectError(error.InvalidWardrobe, fixture("{\"outfits\":[]}"));
    try t.expectError(error.InvalidWardrobe, fixture("{\"outfits\":[{\"id\":\"auto\",\"displayName\":\"Auto\",\"spritesheetPath\":\"outfits/auto.webp\"}]}"));
    try t.expectError(error.InvalidWardrobe, fixture("{\"outfits\":[{\"id\":\"night\",\"displayName\":\"Night\",\"spritesheetPath\":\"../night.webp\"}]}"));
    try t.expectError(error.InvalidWardrobe, fixture(fixture_outfits ++ ",\"schedule\":[{\"outfit\":\"unknown\",\"when\":{\"days\":[\"sun\"]}}]}"));
    try t.expectError(error.InvalidWardrobe, fixture(fixture_outfits ++ ",\"schedule\":[{\"outfit\":\"night\",\"when\":{\"dates\":{\"from\":\"02-30\",\"to\":\"03-01\"}}}]}"));
    try t.expectError(error.InvalidWardrobe, fixture(fixture_outfits ++ ",\"schedule\":[{\"outfit\":\"night\",\"when\":{\"time\":{\"from\":\"07:00\",\"to\":\"07:00\"}}}]}"));
    try t.expectError(error.InvalidWardrobe, fixture(fixture_outfits ++ ",\"schedule\":[{\"outfit\":\"night\",\"when\":{}}]}"));
}
