//! Worker-side archive import bridge. The serialized catalog owner supplies
//! approved private roots. The scratch directory must be unique per install,
//! and must not be the downloaded asset's original user directory.
const std = @import("std");
const zip = @import("companion/pet_zip.zig");
const download = @import("companion/pet_market_download.zig");
const importing = @import("companion/pet_import.zig");
const inventory = @import("companion/pet_inventory.zig");
const store = @import("companion_catalog_store.zig");
const Budget = @import("runtime_budget").Budget;

pub const Install = struct {
    stage: zip.Stage = .{},
    charged: usize = 0,
    recovery_required: bool = false,

    /// Catalog operations remain serialized. Reserve a worst-case extraction
    /// AND package copy until cleanup. The installed asset itself needs a
    /// separate durable inventory/disk policy. Caller retains downloaded
    /// archive ownership until this operation returns. No publication before
    /// all ZIP payloads, CRCs and the actual package validator succeed.
    pub fn run(self: *Install, io: std.Io, scratch: std.Io.Dir, scratch_path: []const u8, budget: *Budget, archive: download.Result, root: [*:0]const u16, owner: *importing.Coordinator, helper: anytype, source_id: []const u8) !importing.Result {
        if (owner.fault != null) return error.RecoveryRequired;
        if (!inventory.validSource(source_id)) return error.Invalid;
        var path: [4096]u8 = undefined;
        const source = try self.unpack(io, scratch, scratch_path, budget, archive, &path);
        return store.importPackage(root, owner, helper, source, source_id) catch |err| {
            // An ambiguous managed copy may survive scratch cleanup.
            self.recovery_required = owner.fault != null;
            return err;
        };
    }

    // Both legacy fixture and production lease-bound consumer use the
    // same bounded ZIP admission/extraction and cleanup accounting.
    pub fn unpack(self: *Install, io: std.Io, scratch: std.Io.Dir, scratch_path: []const u8, budget: *Budget, archive: download.Result, path: []u8) ![]const u8 {
        if (self.charged != 0 or self.stage.root_created or self.recovery_required) return error.Busy;
        const size = (try archive.file.stat(io)).size;
        if (size == 0 or size != archive.bytes or size > zip.max_archive_bytes) return error.InvalidArchive;
        const source = try std.fmt.bufPrint(path, "{s}\\unpacked", .{scratch_path});
        // scratch_path is the caller-approved absolute path of scratch.
        // The existing helper independently validates normal local paths.
        const charge = 2 * zip.max_archive_bytes;
        try budget.reserve(charge);
        self.charged = charge;
        try self.stage.extract(io, archive.file, scratch);
        return source;
    }

    /// Call after all package readers stop, including on run failure.
    /// Do not release the temporary quota when directory cleanup fails.
    pub fn cleanup(self: *Install, io: std.Io, scratch: std.Io.Dir, budget: *Budget) !void {
        try self.stage.cleanup(io, scratch);
        if (self.recovery_required) return error.RecoveryRequired;
        if (self.charged != 0) {
            budget.release(self.charged);
            self.charged = 0;
        }
    }
};
