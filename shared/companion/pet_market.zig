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

pub const SearchIndex = struct {
    version: u32,
    generatedAt: []const u8,
    total: u32,
    pageSize: u32,
    pages: []const []const u8,
};

pub const SearchPet = struct {
    id: []const u8,
    displayName: []const u8,
    searchText: []const u8,
    category: []const u8,
    catalogPage: u32,
    original: bool = false,
    featured: bool = false,
    spriteVersionNumber: ?u32 = null,
};

pub const SearchPage = struct {
    version: u32,
    page: u32,
    pageSize: u32,
    pets: []const SearchPet,
};

/// Bind every search response to the root revision. The caller fetches
/// only the URL in root.search and the returned validated page URLs.
pub fn parseSearchIndex(allocator: std.mem.Allocator, input: []const u8, root: Index) Error!std.json.Parsed(SearchIndex) {
    const parsed = try parse(SearchIndex, allocator, input);
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value.version != 3 or value.total != root.total or value.total > max_total or
        value.pageSize == 0 or value.pageSize > 1000 or
        !std.mem.eql(u8, value.generatedAt, root.generatedAt) or
        value.pages.len != (value.total + value.pageSize - 1) / value.pageSize) return error.InvalidCatalog;
    for (value.pages, 0..) |url, n| {
        if (!validUrl(url, .catalog) or std.mem.eql(u8, url, root.search)) return error.InvalidCatalog;
        for (value.pages[0..n]) |prior| {
            if (std.mem.eql(u8, prior, url)) return error.InvalidCatalog;
        }
        for (root.pages) |detail| {
            if (std.mem.eql(u8, detail, url)) return error.InvalidCatalog;
        }
    }
    return parsed;
}

pub fn parseSearchPage(allocator: std.mem.Allocator, input: []const u8, root: Index, index: SearchIndex, number: u32) Error!std.json.Parsed(SearchPage) {
    if (number >= index.pages.len or index.total != root.total or index.pageSize == 0 or index.pageSize > 1000 or
        !std.mem.eql(u8, index.generatedAt, root.generatedAt)) return error.InvalidCatalog;
    const offset = @as(u64, number) * index.pageSize;
    if (offset >= index.total) return error.InvalidCatalog;
    const expected = @min(index.pageSize, index.total - offset);
    const parsed = try parse(SearchPage, allocator, input);
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value.version != 3 or value.page != number or value.pageSize != index.pageSize or
        value.pets.len != expected) return error.InvalidCatalog;
    for (value.pets, 0..) |pet, n| {
        if (!inventory.validSource(pet.id) or !checkedText(pet.displayName, 480) or !checkedText(pet.searchText, 1600) or
            pet.catalogPage >= root.pages.len or
            (!std.mem.eql(u8, pet.category, "asian") and !std.mem.eql(u8, pet.category, "western"))) return error.InvalidCatalog;
        if (pet.spriteVersionNumber) |version| {
            if (version != 1 and version != 2) return error.InvalidCatalog;
        }
        for (value.pets[0..n]) |prior| {
            if (std.mem.eql(u8, prior.id, pet.id)) return error.InvalidCatalog;
        }
    }
    return parsed;
}

pub const Filter = struct {
    query: []const u8 = "",
    category: enum { any, asian, western } = .any,
    version: enum { any, v1, v2 } = .any,
    curated: bool = true,
    exact_id: bool = false,
    original_only: bool = false,
    featured_only: bool = false,

    fn validate(self: Filter) Error!void {
        if (self.query.len > 256 or (self.query.len != 0 and !checkedText(self.query, 256))) return error.InvalidCatalog;
        if (self.exact_id and !inventory.validSource(self.query)) return error.InvalidCatalog;
    }

    fn matches(self: Filter, pet: SearchPet) bool {
        if (self.exact_id) return std.mem.eql(u8, pet.id, self.query);
        if (self.curated and !pet.original and !pet.featured) return false;
        if (self.original_only and !pet.original) return false;
        if (self.featured_only and !pet.featured) return false;
        switch (self.category) {
            .any => {},
            .asian => if (!std.mem.eql(u8, pet.category, "asian")) return false,
            .western => if (!std.mem.eql(u8, pet.category, "western")) return false,
        }
        switch (self.version) {
            .any => {},
            .v1 => if ((pet.spriteVersionNumber orelse 1) != 1) return false,
            .v2 => if ((pet.spriteVersionNumber orelse 1) != 2) return false,
        }
        var terms = std.mem.tokenizeScalar(u8, self.query, ' ');
        while (terms.next()) |term| {
            if (!containsFolded(pet.id, term) and !containsFolded(pet.displayName, term) and
                !containsFolded(pet.searchText, term)) return false;
        }
        return true;
    }
};

// Fold ASCII only; UTF-8 non-ASCII bytes are matched exactly, including
// Chinese/Japanese names. Full Unicode case folding is not implemented.
fn containsFolded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(haystack[offset..][0..needle.len], needle)) return true;
    }
    return false;
}

pub const Hit = struct {
    id: [64]u8 = undefined,
    id_len: usize,
    name: [480]u8 = undefined,
    name_len: usize,
    catalog_page: u32,

    fn copy(pet: SearchPet) Hit {
        var hit: Hit = .{ .id_len = pet.id.len, .name_len = pet.displayName.len, .catalog_page = pet.catalogPage };
        @memcpy(hit.id[0..hit.id_len], pet.id);
        @memcpy(hit.name[0..hit.name_len], pet.displayName);
        return hit;
    }

    pub fn sourceId(self: *const Hit) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn displayName(self: *const Hit) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Scan one validated search page at a time. Keep only the requested
/// result window and an owned ID set to reject duplicates across pages.
/// Caller supplies bounded allocator, copied query and output buffer;
/// all must outlive Scan. Results are provisional until finish succeeds.
pub const Scan = struct {
    allocator: std.mem.Allocator,
    seen: std.StringHashMap(void),
    filter: Filter,
    offset: usize,
    output: []Hit,
    next_page: u32 = 0,
    read: usize = 0,
    matched: usize = 0,
    written: usize = 0,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, filter: Filter, offset: usize, output: []Hit) Error!Scan {
        try filter.validate();
        if (offset > max_total or output.len > 128) return error.InvalidCatalog;
        return .{ .allocator = allocator, .seen = std.StringHashMap(void).init(allocator), .filter = filter, .offset = offset, .output = output };
    }

    pub fn deinit(self: *Scan) void {
        var keys = self.seen.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.seen.deinit();
        self.failed = true;
    }

    pub fn append(self: *Scan, page: SearchPage) Error!void {
        if (self.failed) return error.InvalidCatalog;
        errdefer self.failed = true;
        if (page.page != self.next_page or page.pets.len > max_total - self.read) return error.InvalidCatalog;
        for (page.pets) |pet| {
            if (!inventory.validSource(pet.id) or !checkedText(pet.displayName, 480)) return error.InvalidCatalog;
            if (self.seen.contains(pet.id)) return error.InvalidCatalog;
            const key = try self.allocator.dupe(u8, pet.id);
            errdefer self.allocator.free(key);
            try self.seen.put(key, {});
            self.read += 1;
            if (self.filter.matches(pet)) {
                if (self.matched >= self.offset and self.written < self.output.len) {
                    self.output[self.written] = Hit.copy(pet);
                    self.written += 1;
                }
                self.matched += 1;
            }
        }
        self.next_page += 1;
    }

    pub const Summary = struct { total: usize, written: usize };

    pub fn finish(self: *const Scan, index: SearchIndex) Error!Summary {
        if (self.failed or self.next_page != index.pages.len or self.read != index.total) return error.InvalidCatalog;
        return .{ .total = self.matched, .written = self.written };
    }
};

/// Re-resolve a selected result on its validated detail page before install.
/// A search row never grants access to a download URL by itself.
pub fn resolveHit(hit: *const Hit, detail: Page) Error!Pet {
    if (hit.id_len > hit.id.len or hit.name_len > hit.name.len or detail.page != hit.catalog_page) return error.InvalidCatalog;
    for (detail.pets) |pet| {
        if (std.mem.eql(u8, pet.id, hit.sourceId())) return pet;
    }
    return error.InvalidCatalog;
}

test "search pages bind generation and collect bounded curated results across pages" {
    const allocator = std.testing.allocator;
    const root = Index{ .version = 3, .generatedAt = "revision-1", .total = 3, .pageSize = 2, .search = "https://openpets.dev/pets/catalog.v3/rev/search.json", .pages = &.{ "https://openpets.dev/pets/catalog.v3/rev/detail0.json", "https://openpets.dev/pets/catalog.v3/rev/detail1.json" } };
    const parsed = try parseSearchIndex(allocator, "{\"version\":3,\"generatedAt\":\"revision-1\",\"total\":3,\"pageSize\":2,\"pages\":[\"https://openpets.dev/pets/catalog.v3/rev/s0.json\",\"https://openpets.dev/pets/catalog.v3/rev/s1.json\"]}", root);
    defer parsed.deinit();
    const first = try parseSearchPage(allocator, "{\"version\":3,\"page\":0,\"pageSize\":2,\"pets\":[{\"id\":\"cat\",\"displayName\":\"猫咪\",\"searchText\":\"Cute Cat\",\"category\":\"asian\",\"catalogPage\":0,\"featured\":true},{\"id\":\"hidden\",\"displayName\":\"Cat 2\",\"searchText\":\"cute\",\"category\":\"asian\",\"catalogPage\":0}]}", root, parsed.value, 0);
    defer first.deinit();
    const second = try parseSearchPage(allocator, "{\"version\":3,\"page\":1,\"pageSize\":2,\"pets\":[{\"id\":\"dog\",\"displayName\":\"小狗\",\"searchText\":\"Cute DOG\",\"category\":\"western\",\"catalogPage\":1,\"original\":true,\"spriteVersionNumber\":2}]}", root, parsed.value, 1);
    defer second.deinit();
    var hits: [1]Hit = undefined;
    var scan = try Scan.init(allocator, .{ .query = "CUTE" }, 1, &hits);
    defer scan.deinit();
    try scan.append(first.value);
    try std.testing.expectError(error.InvalidCatalog, scan.finish(parsed.value));
    try scan.append(second.value);
    const summary = try scan.finish(parsed.value);
    try std.testing.expectEqual(@as(usize, 2), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.written);
    try std.testing.expectEqualStrings("dog", hits[0].sourceId());
    try std.testing.expectEqualStrings("小狗", hits[0].displayName());
    var exact = try Scan.init(allocator, .{ .query = "hidden", .exact_id = true }, 0, &hits);
    defer exact.deinit();
    try exact.append(first.value);
    try exact.append(second.value);
    try std.testing.expectEqual(@as(usize, 1), (try exact.finish(parsed.value)).total);
    try std.testing.expectEqualStrings("hidden", hits[0].sourceId());
    var duplicate = try Scan.init(allocator, .{}, 0, &hits);
    defer duplicate.deinit();
    try duplicate.append(first.value);
    var repeated = second.value;
    repeated.pets = first.value.pets[0..1];
    try std.testing.expectError(error.InvalidCatalog, duplicate.append(repeated));
    try std.testing.expectError(error.InvalidCatalog, duplicate.finish(parsed.value));
    var stale = root;
    stale.generatedAt = "revision-2";
    try std.testing.expectError(error.InvalidCatalog, parseSearchPage(allocator, "{}", stale, parsed.value, 0));
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
