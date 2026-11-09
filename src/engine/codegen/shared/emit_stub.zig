//! JIT emit surface for hosts without a native code generator (wasm32/wasm64).
//!
//! The interpreter engine never calls into the JIT pipeline, but `compile.zig`
//! is still analyzed on every target, so this module provides the same names
//! (`Error`, `CallFixup`, `EmitOutput`, `compile`, `deinit`) with no
//! implementation. Keeping the shape identical is what lets the single
//! `emit` dispatch stay a pure import switch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const exception_table = @import("exception_table.zig");

pub const Error = error{UnsupportedOnThisTarget};

pub const CallFixup = struct {
    byte_offset: u32 = 0,
    target_func_idx: u32 = 0,
    is_tail: bool = false,
};

pub const EmitOutput = struct {
    bytes: []u8 = &.{},
    n_slots: u16 = 0,
    call_fixups: []CallFixup = &.{},
    frame_bytes: u32 = 0,
    oob_stub_off: u32 = 0,
    exception_handlers: []const exception_table.HandlerEntry = &.{},
};

pub fn compile(
    allocator: Allocator,
    func: anytype,
    alloc: anytype,
    func_sigs: anytype,
    module_types: anytype,
    num_imports: anytype,
    globals_offsets: anytype,
    globals_valtypes: anytype,
    memory0_idx_type: anytype,
    tag_typeidxs: anytype,
    uses_type_subtyping: anytype,
    bounds_elided: anytype,
) Error!EmitOutput {
    _ = .{ allocator, func, alloc, func_sigs, module_types, num_imports, globals_offsets, globals_valtypes, memory0_idx_type, tag_typeidxs, uses_type_subtyping, bounds_elided };
    return error.UnsupportedOnThisTarget;
}

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
}
