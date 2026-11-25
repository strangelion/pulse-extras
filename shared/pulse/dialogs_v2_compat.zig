//! Additive Pulse 1.0.61 / Preview 3 pulse.dialogs V2 ABI adapter.
//! The public pinned baseline still provides the frozen V1 prefix only.
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");

pub const name = "pulse.dialogs";
pub const version: u32 = 2;

pub const StateChangedFn = *const fn (?*anyopaque, u64, [*c]const raw.PulseUiState, u32) callconv(.c) void;
pub const ClosedFn = *const fn (?*anyopaque, u64, abi.Status, abi.StringView, [*c]const raw.PulseUiState, u32) callconv(.c) void;
pub const CommandFn = *const fn (?*anyopaque, u64, abi.StringView) callconv(.c) void;

pub const ShowFn = *const fn (?*anyopaque, *const raw.PulseDialogRequest, ?StateChangedFn, ?ClosedFn, ?*anyopaque, *u64) callconv(.c) abi.Status;
pub const SetStatesFn = *const fn (?*anyopaque, u64, [*]const raw.PulseUiState, u32) callconv(.c) abi.Status;
pub const CloseFn = *const fn (?*anyopaque, u64) callconv(.c) abi.Status;
pub const SubscribeCommandFn = *const fn (?*anyopaque, u64, abi.StringView, CommandFn, ?*anyopaque, *u64) callconv(.c) abi.Status;
pub const UnsubscribeCommandFn = *const fn (?*anyopaque, u64) callconv(.c) abi.Status;
pub const UpdateModelFn = *const fn (?*anyopaque, u64, *const raw.PulseUiModelTree) callconv(.c) abi.Status;
pub const GetStateFn = *const fn (?*anyopaque, u64, abi.StringView, [*]u8, u32, *u32) callconv(.c) abi.Status;

pub const Table = extern struct {
    size: u32,
    version: u32,
    context: ?*anyopaque,
    show: ?ShowFn,
    set_states: ?SetStatesFn,
    close: ?CloseFn,
    subscribe_command: ?SubscribeCommandFn,
    unsubscribe_command: ?UnsubscribeCommandFn,
    update_model: ?UpdateModelFn,
    get_state: ?GetStateFn,
};

comptime {
    if (@sizeOf(Table) != 72) @compileError("PulseDialogsV2 must be 72 bytes on x86_64");
    if (@offsetOf(Table, "subscribe_command") != 40) @compileError("PulseDialogsV2 subscribe_command offset");
    if (@offsetOf(Table, "unsubscribe_command") != 48) @compileError("PulseDialogsV2 unsubscribe_command offset");
    if (@offsetOf(Table, "update_model") != 56) @compileError("PulseDialogsV2 update_model offset");
    if (@offsetOf(Table, "get_state") != 64) @compileError("PulseDialogsV2 get_state offset");
}
