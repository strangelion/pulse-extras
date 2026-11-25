//! Default provisioning source: no review, no authorization, no CLI.
const std = @import("std");
const approval = @import("vcs_approval");
const host = @import("pulse_host");

pub fn acquire(_: std.mem.Allocator) host.Error!?approval.NativeInput {
    return null;
}
