//! OpenPets public pet catalog V3 protocol boundary, no network side effects.
//! Caller supplies a bounded scratch allocator and fetches only validated URLs.
//! Upstream: https://docs.openpets.dev/catalog/ and catalog-validation.ts.
const std = @import("std");
const inventory = @import("pet_inventory.zig");

pub const index_url = "https://openpets.dev/pets/catalog.v3.json";
pub const max_response_bytes = 4 * 1024 * 1024;
pub const max_total = 10_000;
pub const Error = error{ InvalidCatalog, OutOfMemory };
pub const UrlKind = enum { catalog, preview, zip };

pub fn validUrl(url: []const u8, kind: UrlKind) bool {
    if (url.len > 2048) return false;
    const prefix = switch (kind) {
        .catalog => "https://openpets.dev/pets/catalog.v3/",
        .preview => "https://openpets.dev/pets/",
        .zip => "https://zip.openpets.dev/pets/",
    };
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const path = url[prefix.len..];
    // Deliberately stricter than browser URL normalization: no encoded
    // separators, credentials, queries, fragments, aliases or redirects.
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
        }
    }
    return switch (kind) {
        .catalog => std.mem.endsWith(u8, path, ".json"),
        .preview => std.mem.endsWith(u8, path, ".webp") or std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".svg"),
        .zip => std.mem.endsWith(u8, path, ".zip"),
    };
}

fn checkedText(value: []const u8, limit: usize) bool {
    if (value.len == 0 or value.len > limit or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |ch| {
        if (ch < 32 or ch == 127) return false;
    }
    return true;
}

pub const Index = struct {
    version: u32,
    generatedAt: []const u8,
    total: u32,
    pageSize: u32,
    search: []const u8,
    pages: []const []const u8,
};

pub const Pet = struct {
    id: []const u8,
    displayName: []const u8,
    description: []const u8,
    thumbnail: []const u8,
    spritesheet: []const u8,
    zip: []const u8,
    category: []const u8,
    subcategory: ?[]const u8 = null,
    original: bool = false,
    featured: bool = false,
    spriteVersionNumber: ?u32 = null,
    wardrobeZip: ?[]const u8 = null,
    minOpenPetsVersion: ?[]const u8 = null,

    pub fn compatible(self: Pet) bool {
        // Do not render remote SVG or execute plugins. Future version
        // requirements are shown, not equated with a Pulse version.
        return std.mem.endsWith(u8, self.spritesheet, ".webp") and self.minOpenPetsVersion == null;
    }

    pub fn download(self: Pet, full: bool) ?[]const u8 {
        if (!self.compatible()) return null;
        return if (full) self.wardrobeZip orelse self.zip else self.zip;
    }
};

pub const Page = struct {
    version: u32,
    page: u32,
    pageSize: u32,
    pets: []const Pet,
};

fn parse(comptime T: type, allocator: std.mem.Allocator, input: []const u8) Error!std.json.Parsed(T) {
    if (input.len == 0 or input.len > max_response_bytes or !std.unicode.utf8ValidateSlice(input)) return error.InvalidCatalog;
    return std.json.parseFromSlice(T, allocator, input, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCatalog,
    };
}

pub fn parseIndex(allocator: std.mem.Allocator, input: []const u8) Error!std.json.Parsed(Index) {
    const parsed = try parse(Index, allocator, input);
    errdefer parsed.deinit();
    const index = parsed.value;
    if (index.version != 3 or index.total > max_total or index.pageSize == 0 or index.pageSize > 500 or
        !checkedText(index.generatedAt, 64) or !validUrl(index.search, .catalog)) return error.InvalidCatalog;
    if (index.pages.len != (index.total + index.pageSize - 1) / index.pageSize) return error.InvalidCatalog;
    for (index.pages, 0..) |url, n| {
        if (!validUrl(url, .catalog)) return error.InvalidCatalog;
        for (index.pages[0..n]) |prior| {
            if (std.mem.eql(u8, prior, url)) return error.InvalidCatalog;
        }
    }
    return parsed;
}

pub fn parsePage(allocator: std.mem.Allocator, input: []const u8, expected_page: u32, expected_size: u32) Error!std.json.Parsed(Page) {
    const parsed = try parse(Page, allocator, input);
    errdefer parsed.deinit();
    const page = parsed.value;
    if (page.version != 3 or page.page != expected_page or page.pageSize != expected_size or
        page.pageSize == 0 or page.pageSize > 500 or page.pets.len > page.pageSize) return error.InvalidCatalog;
    for (page.pets, 0..) |pet, n| {
        if (!inventory.validSource(pet.id) or !checkedText(pet.displayName, 480) or !checkedText(pet.description, 2000) or
            !validUrl(pet.thumbnail, .preview) or !validUrl(pet.spritesheet, .preview) or !validUrl(pet.zip, .zip) or
            (!std.mem.eql(u8, pet.category, "western") and !std.mem.eql(u8, pet.category, "asian"))) return error.InvalidCatalog;
        if (pet.spriteVersionNumber) |version| {
            if (version != 1 and version != 2) return error.InvalidCatalog;
        }
        if (pet.subcategory) |value| {
            if (!checkedText(value, 320)) return error.InvalidCatalog;
        }
        if (pet.wardrobeZip) |url| {
            if (!validUrl(url, .zip)) return error.InvalidCatalog;
        }
        if (pet.minOpenPetsVersion) |version| {
            if (!checkedText(version, 32)) return error.InvalidCatalog;
        }
        for (page.pets[0..n]) |prior| {
            if (std.mem.eql(u8, prior.id, pet.id)) return error.InvalidCatalog;
        }
    }
    return parsed;
}

test "market URLs reject redirects by alias and unsafe paths" {
    try std.testing.expect(validUrl("https://zip.openpets.dev/pets/cat/abc.zip", .zip));
    try std.testing.expect(validUrl("https://openpets.dev/pets/catalog.v3/rev/page-000.json", .catalog));
    for ([_][]const u8{
        "http://zip.openpets.dev/pets/cat/a.zip",
        "https://zip.openpets.dev.evil.test/pets/cat/a.zip",
        "https://zip.openpets.dev/pets/../plugins/a.zip",
        "https://zip.openpets.dev/pets/cat/%2e%2e/a.zip",
        "https://zip.openpets.dev/pets/cat/a.zip?url=evil",
        "https://zip.openpets.dev/plugins/a.zip",
    }) |url| try std.testing.expect(!validUrl(url, .zip));
}

test "bounded V3 index and page with base and full packages" {
    const index_input =
        \\{"version":3,"generatedAt":"2026-11-25T00:00:00Z","total":1,"pageSize":20,"search":"https://openpets.dev/pets/catalog.v3/rev/search.json","pages":["https://openpets.dev/pets/catalog.v3/rev/page-000.json"],"filters":{"categories":[]}}
    ;
    const index = try parseIndex(std.testing.allocator, index_input);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 1), index.value.pages.len);
    const input =
        \\{"version":3,"page":0,"pageSize":20,"pets":[{"id":"cat","displayName":"猫咪","description":"Fixture","thumbnail":"https://openpets.dev/pets/cat/thumb.webp","spritesheet":"https://openpets.dev/pets/cat/spritesheet.webp","zip":"https://zip.openpets.dev/pets/cat/base.zip","wardrobeZip":"https://zip.openpets.dev/pets/cat/full.zip","category":"asian","spriteVersionNumber":1}]}
    ;
    const page = try parsePage(std.testing.allocator, input, 0, 20);
    defer page.deinit();
    const pet = page.value.pets[0];
    try std.testing.expectEqualStrings("猫咪", pet.displayName);
    try std.testing.expectEqualStrings("https://zip.openpets.dev/pets/cat/full.zip", pet.download(true).?);
    try std.testing.expectError(error.InvalidCatalog, parsePage(std.testing.allocator, input, 1, 20));
    var unsupported = pet;
    unsupported.spritesheet = "https://openpets.dev/pets/cat/spritesheet.svg";
    try std.testing.expect(unsupported.download(false) == null);
}
