//! Platform allocator + process-environment access.
//!
//! The C-ABI layer was written for native hosts and pins `std.heap.c_allocator`.
//! wasm64-wasi has no libc at all, so the browser build substitutes Zig's
//! `wasm_allocator` and answers env queries with "empty". Keeping the switch in
//! one module lets the native build keep its libc semantics unchanged.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;

pub const allocator: std.mem.Allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.c_allocator;

var wasm_environ_null: [1]?[*:0]u8 = .{null};

pub fn getenv(name: [*:0]const u8) ?[*:0]u8 {
    return if (comptime is_wasm) null else std.c.getenv(name);
}

pub fn environ() [*:null]?[*:0]u8 {
    return if (comptime is_wasm) @ptrCast(&wasm_environ_null) else std.c.environ;
}
