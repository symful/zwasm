//! zwasm Flutter plugin shim.
//!
//! A flat C ABI over zwasm's Zig facade (`Engine` / `Module` / `Instance`),
//! consumed by `dart:ffi` on Android/Windows and by the JS bridge on the web.
//! Everything here is deliberately scalar-only: no struct layouts cross the
//! boundary, so the Dart and JavaScript sides share one contract.
//!
//! Value encoding (`u64` slots):
//!   i32 -> zero-extended low 32 bits
//!   i64 -> bit pattern
//!   f32 -> bit pattern in low 32 bits
//!   f64 -> bit pattern
//!   ref -> funcref/externref payload (0 = null)
//!
//! Kind codes: 0 i32, 1 i64, 2 f32, 3 f64, 4 v128, 5 funcref, 6 externref.

const std = @import("std");
const builtin = @import("builtin");
const zwasm = @import("zwasm");

const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;
const gpa: std.mem.Allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.c_allocator;

// ── wasm64 host stubs ──────────────────────────────────────────────────────
// Zig's wasi std references these two libc globals; wasm64 has no libc, so
// the plugin module supplies them. Harmless no-ops on native (not exported).
var wasm_errno: c_int = 0;
var wasm_environ_null: [1]?[*:0]u8 = .{null};
comptime {
    if (is_wasm) {
        @export(&wasm_errno, .{ .name = "errno" });
        @export(&wasm_environ_null, .{ .name = "environ" });
    }
}

pub const ZW_OK: i32 = 0;
pub const ZW_ERR_TRAP: i32 = 1;
pub const ZW_ERR_COMPILE: i32 = 2;
pub const ZW_ERR_INSTANTIATE: i32 = 3;
pub const ZW_ERR_NOT_FOUND: i32 = 4;
pub const ZW_ERR_ARITY: i32 = 5;
pub const ZW_ERR_MEMORY: i32 = 6;
pub const ZW_ERR_GLOBAL: i32 = 7;
pub const ZW_ERR_INVALID_ARG: i32 = 8;
pub const ZW_ERR_INTERNAL: i32 = 9;
pub const ZW_ERR_WASI_EXIT: i32 = 10;

var last_error_code: i32 = ZW_OK;
var last_error_buf: [1024]u8 = undefined;
var last_error_len: usize = 0;

fn clearError() void {
    last_error_code = ZW_OK;
    last_error_len = 0;
}

fn setError(code: i32, comptime fmt: []const u8, args: anytype) void {
    last_error_code = code;
    const text = std.fmt.bufPrint(&last_error_buf, fmt, args) catch last_error_buf[0..];
    last_error_len = text.len;
}

fn setErrorName(code: i32, err: anyerror) void {
    setError(code, "{s}", .{@errorName(err)});
}

// ── version ────────────────────────────────────────────────────────────────

const version_text = zwasm.version ++ "\x00";

export fn zw_version() callconv(.c) [*:0]const u8 {
    return version_text[0..zwasm.version.len :0].ptr;
}

export fn zw_version_len() callconv(.c) u32 {
    return @intCast(zwasm.version.len);
}

/// Host-allocated scratch buffer (used by Dart to stage module bytes and
/// export names). Pair with `zw_free(ptr, len)`.
export fn zw_alloc(len: usize) callconv(.c) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn zw_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

export fn zw_last_error_code() callconv(.c) i32 {
    return last_error_code;
}

export fn zw_last_error_message(buf: [*]u8, cap: usize) callconv(.c) usize {
    const n = @min(cap, last_error_len);
    @memcpy(buf[0..n], last_error_buf[0..n]);
    return n;
}

// ── kind mapping ───────────────────────────────────────────────────────────

fn kindOf(vt: zwasm.ir.zir.ValType) u8 {
    return switch (vt) {
        .i32 => 0,
        .i64 => 1,
        .f32 => 2,
        .f64 => 3,
        .v128 => 4,
        .ref => 5,
    };
}

fn decodeValue(vt: zwasm.ir.zir.ValType, bits: u64) zwasm.Value {
    return switch (vt) {
        .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(bits))) },
        .i64 => .{ .i64 = @bitCast(bits) },
        .f32 => .{ .f32 = @truncate(bits) },
        .f64 => .{ .f64 = bits },
        .v128 => .{ .v128 = @as(u128, bits) },
        .ref => .{ .funcref = if (bits == 0) null else bits },
    };
}

fn encodeValue(v: zwasm.Value) u64 {
    return switch (v) {
        .i32 => |x| @as(u32, @bitCast(x)),
        .i64 => |x| @bitCast(x),
        .f32 => |x| x,
        .f64 => |x| x,
        .v128 => |x| @truncate(x),
        .funcref => |x| x orelse 0,
        .externref => |x| x orelse 0,
    };
}

fn externKindCode(k: zwasm.ExternKind) u8 {
    return switch (k) {
        .func => 0,
        .table => 1,
        .memory => 2,
        .global => 3,
        .tag => 4,
    };
}

// ── handles ────────────────────────────────────────────────────────────────

const EngineH = struct {
    engine: zwasm.Engine,
    refs: u32 = 1,
};

const ModuleH = struct {
    module: zwasm.Module,
    engine: *EngineH,
    /// The parser's section bodies borrow the compile input, so the module
    /// must keep a copy alive for its whole lifetime.
    bytes: []u8,
    exports: ?zwasm.ModuleExports = null,
    imports: ?zwasm.ModuleImports = null,
    refs: u32 = 1,
};

/// Host-side context handed to a `Linker.defineFuncRaw` thunk. The thunk
/// recovers it from `Caller.host_data`; the import's Dart/JS callback is
/// invoked with `user_ctx` + the import index.
const HostCtx = struct {
    cb: ?ZWHostCallback,
    user_ctx: ?*anyopaque,
    index: u32,
    module_name: []u8,
    import_name: []u8,
    params: []zwasm.ir.zir.ValType,
    results: []zwasm.ir.zir.ValType,
};

/// Web-only bridge from the plugin wasm module to the JS host dispatch.
extern "env" fn zwJsHostCall(
    ctx: ?*anyopaque,
    import_index: u32,
    args: [*]const u64,
    n_args: u32,
    results: [*]u64,
    n_results: u32,
) callconv(.c) i32;

const InstanceH = struct {
    instance: zwasm.Instance,
    module: *ModuleH,
    /// The Linker MUST outlive the instance: host/WASI CallCtx slots live in
    /// it and the guest keeps raw pointers into them.
    linker: ?*zwasm.Linker = null,
    host_ctxs: std.ArrayList(*HostCtx) = .empty,
    vfs: ?*zwasm.vfs.MemFs = null,
    wasi_ctxs: std.ArrayList(*WasiFnCtx) = .empty,
    refs: u32 = 1,
};

const WasiEnv = struct { name: []u8, value: []u8 };
const WasiPreopen = struct { host: []u8, guest: []u8 };
const CfgFile = struct { path: []u8, data: []u8, writable: bool };
const CfgDir = struct { path: []u8, writable: bool };

const WasiCfgH = struct {
    args: std.ArrayList([]u8) = .empty,
    envs: std.ArrayList(WasiEnv) = .empty,
    preopens: std.ArrayList(WasiPreopen) = .empty,
    files: std.ArrayList(CfgFile) = .empty,
    dirs: std.ArrayList(CfgDir) = .empty,
};

/// C ABI for a host import callback. `args`/`results` are u64 value slots
/// (same encoding as `zw_instance_invoke`). Return 0 on success; non-zero
/// traps the guest.
pub const ZWHostCallback = *const fn (
    ctx: ?*anyopaque,
    import_index: u32,
    args: [*]const u64,
    n_args: u32,
    results: [*]u64,
    n_results: u32,
) callconv(.c) i32;

/// One host import descriptor. Mirrors the Dart FFI struct and the JS bridge
/// object field-for-field.
pub const ZWImportDesc = extern struct {
    module: [*]const u8,
    module_len: usize,
    name: [*]const u8,
    name_len: usize,
    params: [*]const u8,
    params_len: usize,
    results: [*]const u8,
    results_len: usize,
};

fn scalarValType(code: u8) ?zwasm.ir.zir.ValType {
    return switch (code) {
        0 => .i32,
        1 => .i64,
        2 => .f32,
        3 => .f64,
        else => null,
    };
}

fn hostThunk(caller: *zwasm.Caller, args: []const zwasm.RuntimeValue, results: []zwasm.RuntimeValue) anyerror!void {
    const hc: *HostCtx = @ptrCast(@alignCast(caller.host_data orelse return error.HostTrap));
    if (args.len > 64 or results.len > 64) return error.HostTrap;
    var arg_bits: [64]u64 = undefined;
    var res_bits: [64]u64 = undefined;
    for (args, 0..) |v, i| {
        arg_bits[i] = switch (hc.params[i]) {
            .i32, .f32 => v.bits64 & 0xFFFF_FFFF,
            else => v.bits64,
        };
    }
    for (results) |*v| v.* = .{ .bits64 = 0 };
    const rc = if (comptime is_wasm)
        zwJsHostCall(
            hc.user_ctx,
            hc.index,
            &arg_bits,
            @intCast(args.len),
            &res_bits,
            @intCast(results.len),
        )
    else
        (hc.cb orelse return error.HostTrap)(
            hc.user_ctx,
            hc.index,
            &arg_bits,
            @intCast(args.len),
            &res_bits,
            @intCast(results.len),
        );
    if (rc != 0) {
        setError(
            ZW_ERR_TRAP,
            "host import {s}.{s} (#{d}) returned error {d}",
            .{ hc.module_name, hc.import_name, hc.index, rc },
        );
        return error.HostTrap;
    }
    for (results, 0..) |*v, i| v.* = .{ .bits64 = res_bits[i] };
}

// ── in-memory WASI filesystem host functions ───────────────────────────────

const WasiFnCtx = struct {
    fs: *zwasm.vfs.MemFs,
    fnc: zwasm.vfs.WasiFn,
};

fn wasiThunk(caller: *zwasm.Caller, args: []const zwasm.RuntimeValue, results: []zwasm.RuntimeValue) anyerror!void {
    const ctx: *WasiFnCtx = @ptrCast(@alignCast(caller.host_data orelse return error.HostTrap));
    if (results.len != 1) return error.HostTrap;
    const mem = caller.memory() orelse return error.HostTrap;
    results[0] = .{ .i32 = @intCast(ctx.fs.dispatch(ctx.fnc, mem, args)) };
}

const I = zwasm.ir.zir.ValType;
const R1 = [_]I{.i32};
const P1 = [_]I{.i32};
const P2 = [_]I{ .i32, .i32 };
const P3 = [_]I{ .i32, .i32, .i32 };
const P4 = [_]I{ .i32, .i32, .i32, .i32 };
const P6 = [_]I{ .i32, .i32, .i32, .i32, .i32, .i32 };
const SEEK = [_]I{ .i32, .i64, .i32, .i32 };
const READDIR = [_]I{ .i32, .i32, .i32, .i64, .i32 };
const PATH_FILESTAT = [_]I{ .i32, .i32, .i32, .i32, .i32 };
const PATH_OPEN = [_]I{ .i32, .i32, .i32, .i32, .i32, .i64, .i64, .i32, .i32 };
const SET_SIZE = [_]I{ .i32, .i64 };
const SET_TIMES = [_]I{ .i32, .i64, .i64, .i32 };
const ADVISE = [_]I{ .i32, .i64, .i64, .i32 };
const ALLOCATE = [_]I{ .i32, .i64, .i64 };

const WasiDef = struct {
    name: []const u8,
    fnc: zwasm.vfs.WasiFn,
    params: []const I,
};

const wasi_defs = [_]WasiDef{
    .{ .name = "fd_write", .fnc = .fd_write, .params = &P4 },
    .{ .name = "fd_read", .fnc = .fd_read, .params = &P4 },
    .{ .name = "fd_close", .fnc = .fd_close, .params = &P1 },
    .{ .name = "fd_seek", .fnc = .fd_seek, .params = &SEEK },
    .{ .name = "fd_tell", .fnc = .fd_tell, .params = &P2 },
    .{ .name = "fd_fdstat_get", .fnc = .fd_fdstat_get, .params = &P2 },
    .{ .name = "fd_filestat_get", .fnc = .fd_filestat_get, .params = &P2 },
    .{ .name = "fd_filestat_set_size", .fnc = .fd_filestat_set_size, .params = &SET_SIZE },
    .{ .name = "fd_filestat_set_times", .fnc = .fd_filestat_set_times, .params = &SET_TIMES },
    .{ .name = "fd_sync", .fnc = .fd_sync, .params = &P1 },
    .{ .name = "fd_datasync", .fnc = .fd_datasync, .params = &P1 },
    .{ .name = "fd_advise", .fnc = .fd_advise, .params = &ADVISE },
    .{ .name = "fd_allocate", .fnc = .fd_allocate, .params = &ALLOCATE },
    .{ .name = "fd_fdstat_set_flags", .fnc = .fd_fdstat_set_flags, .params = &P2 },
    .{ .name = "fd_prestat_get", .fnc = .fd_prestat_get, .params = &P2 },
    .{ .name = "fd_prestat_dir_name", .fnc = .fd_prestat_dir_name, .params = &P3 },
    .{ .name = "fd_readdir", .fnc = .fd_readdir, .params = &READDIR },
    .{ .name = "path_open", .fnc = .path_open, .params = &PATH_OPEN },
    .{ .name = "path_filestat_get", .fnc = .path_filestat_get, .params = &PATH_FILESTAT },
    .{ .name = "path_create_directory", .fnc = .path_create_directory, .params = &P3 },
    .{ .name = "path_remove_directory", .fnc = .path_remove_directory, .params = &P3 },
    .{ .name = "path_unlink_file", .fnc = .path_unlink_file, .params = &P3 },
    .{ .name = "path_rename", .fnc = .path_rename, .params = &P6 },
};

fn defineWasiFs(
    lk: *zwasm.Linker,
    fs: *zwasm.vfs.MemFs,
    ctxs: *std.ArrayList(*WasiFnCtx),
) !void {
    for (wasi_defs) |d| {
        const ctx = try gpa.create(WasiFnCtx);
        ctx.* = .{ .fs = fs, .fnc = d.fnc };
        try ctxs.append(gpa, ctx);
        try lk.defineFuncRaw(
            "wasi_snapshot_preview1",
            d.name,
            ctx,
            d.params,
            &R1,
            &wasiThunk,
        );
    }
}

fn moduleRetain(m: *ModuleH) void {
    m.refs += 1;
}

fn moduleRelease(m: *ModuleH) void {
    if (m.refs > 1) {
        m.refs -= 1;
        return;
    }
    if (m.exports) |*ex| ex.deinit();
    if (m.imports) |*im| im.deinit();
    m.module.deinit();
    gpa.free(m.bytes);
    const eng = m.engine;
    gpa.destroy(m);
    eng.refs -= 1;
    if (eng.refs == 0) {
        eng.engine.deinit();
        gpa.destroy(eng);
    }
}

// ── engine ─────────────────────────────────────────────────────────────────

export fn zw_engine_new() callconv(.c) ?*anyopaque {
    clearError();
    const h = gpa.create(EngineH) catch {
        setError(ZW_ERR_INTERNAL, "out of memory", .{});
        return null;
    };
    h.* = .{ .engine = zwasm.Engine.init(gpa, .{}) catch {
        gpa.destroy(h);
        setError(ZW_ERR_INTERNAL, "engine init failed", .{});
        return null;
    } };
    return @ptrCast(h);
}

export fn zw_engine_delete(ptr: ?*anyopaque) callconv(.c) void {
    const h: *EngineH = @ptrCast(@alignCast(ptr orelse return));
    h.refs -= 1;
    if (h.refs == 0) {
        h.engine.deinit();
        gpa.destroy(h);
    }
}

// ── module ─────────────────────────────────────────────────────────────────

export fn zw_module_new(engine_ptr: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) ?*anyopaque {
    clearError();
    const eng: *EngineH = @ptrCast(@alignCast(engine_ptr orelse {
        setError(ZW_ERR_INVALID_ARG, "null engine", .{});
        return null;
    }));
    // zwasm's parser stores section bodies as slices into the input buffer,
    // so the module owns a copy for as long as it lives.
    const owned = gpa.dupe(u8, bytes[0..len]) catch {
        setError(ZW_ERR_INTERNAL, "out of memory", .{});
        return null;
    };
    const mod = eng.engine.compile(owned) catch |e| {
        gpa.free(owned);
        setErrorName(ZW_ERR_COMPILE, e);
        return null;
    };
    const h = gpa.create(ModuleH) catch {
        var tmp = mod;
        tmp.deinit();
        gpa.free(owned);
        setError(ZW_ERR_INTERNAL, "out of memory", .{});
        return null;
    };
    h.* = .{
        .module = mod,
        .engine = eng,
        .bytes = owned,
    };
    eng.refs += 1;
    h.exports = mod.exports(gpa) catch null;
    h.imports = mod.imports(gpa) catch null;
    return @ptrCast(h);
}

export fn zw_module_delete(ptr: ?*anyopaque) callconv(.c) void {
    moduleRelease(@ptrCast(@alignCast(ptr orelse return)));
}

export fn zw_module_export_count(ptr: ?*anyopaque) callconv(.c) u32 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 0));
    const ex = h.exports orelse return 0;
    return @intCast(ex.items.len);
}

export fn zw_module_export_kind(ptr: ?*anyopaque, idx: u32) callconv(.c) u8 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 255));
    const ex = h.exports orelse return 255;
    if (idx >= ex.items.len) return 255;
    return externKindCode(ex.items[idx].kind);
}

/// Copies the export name into `buf`; returns the full name length (the
/// caller grows the buffer to that size and queries again).
export fn zw_module_export_name(ptr: ?*anyopaque, idx: u32, buf: [*]u8, cap: usize) callconv(.c) u32 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 0));
    const ex = h.exports orelse return 0;
    if (idx >= ex.items.len) return 0;
    const name = ex.items[idx].name;
    const n = @min(cap, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return @intCast(name.len);
}

export fn zw_module_import_count(ptr: ?*anyopaque) callconv(.c) u32 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 0));
    const im = h.imports orelse return 0;
    return @intCast(im.items.len);
}

export fn zw_module_import_kind(ptr: ?*anyopaque, idx: u32) callconv(.c) u8 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 255));
    const im = h.imports orelse return 255;
    if (idx >= im.items.len) return 255;
    return externKindCode(im.items[idx].kind);
}

/// Copies the import module into `buf`; returns the full length.
export fn zw_module_import_module(ptr: ?*anyopaque, idx: u32, buf: [*]u8, cap: usize) callconv(.c) u32 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 0));
    const im = h.imports orelse return 0;
    if (idx >= im.items.len) return 0;
    const text = im.items[idx].module;
    const n = @min(cap, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return @intCast(text.len);
}

/// Copies the import name into `buf`; returns the full length.
export fn zw_module_import_name(ptr: ?*anyopaque, idx: u32, buf: [*]u8, cap: usize) callconv(.c) u32 {
    const h: *ModuleH = @ptrCast(@alignCast(ptr orelse return 0));
    const im = h.imports orelse return 0;
    if (idx >= im.items.len) return 0;
    const text = im.items[idx].name;
    const n = @min(cap, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return @intCast(text.len);
}

// ── function signatures ────────────────────────────────────────────────────

/// Fills `kinds` with params then results (≤64 total). Returns 0 on success,
/// or a ZW_ERR_* code. `out_params` / `out_results` receive the arities.
export fn zw_instance_func_sig(
    inst_ptr: ?*anyopaque,
    name: [*]const u8,
    name_len: usize,
    kinds: [*]u8,
    out_params: *u32,
    out_results: *u32,
) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return arityError("null instance")));
    const nm = name[0..name_len];
    const sig = h.instance.exportFuncSig(nm) orelse {
        setError(ZW_ERR_NOT_FOUND, "export not found or not a function: {s}", .{nm});
        return ZW_ERR_NOT_FOUND;
    };
    out_params.* = @intCast(sig.params.len);
    out_results.* = @intCast(sig.results.len);
    var i: usize = 0;
    for (sig.params) |p| {
        if (i >= 64) return arityError("signature too large");
        kinds[i] = kindOf(p);
        i += 1;
    }
    for (sig.results) |r| {
        if (i >= 64) return arityError("signature too large");
        kinds[i] = kindOf(r);
        i += 1;
    }
    return ZW_OK;
}

fn arityError(msg: []const u8) i32 {
    setError(ZW_ERR_ARITY, "{s}", .{msg});
    return ZW_ERR_ARITY;
}

/// Invokes `name` with `n_args` u64 slots, writing `n_results` u64 slots.
/// Returns ZW_OK or a ZW_ERR_* code. On ZW_ERR_WASI_EXIT the guest's status
/// is available from `zw_instance_wasi_exit_code`.
export fn zw_instance_invoke(
    inst_ptr: ?*anyopaque,
    name: [*]const u8,
    name_len: usize,
    args: [*]const u64,
    n_args: u32,
    results: [*]u64,
    n_results: u32,
) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return arityError("null instance")));
    const nm = name[0..name_len];
    const sig = h.instance.exportFuncSig(nm) orelse {
        setError(ZW_ERR_NOT_FOUND, "export not found or not a function: {s}", .{nm});
        return ZW_ERR_NOT_FOUND;
    };
    if (sig.params.len != n_args) {
        return arityError("argument count does not match the export signature");
    }
    if (sig.results.len != n_results) {
        return arityError("result count does not match the export signature");
    }

    const arg_vals = gpa.alloc(zwasm.Value, n_args) catch return outOfMemory();
    defer gpa.free(arg_vals);
    const res_vals = gpa.alloc(zwasm.Value, n_results) catch return outOfMemory();
    defer gpa.free(res_vals);
    for (arg_vals, 0..) |*slot, i| slot.* = decodeValue(sig.params[i], args[i]);
    for (res_vals) |*slot| slot.* = .{ .i32 = 0 };

    h.instance.invoke(nm, arg_vals, res_vals) catch |e| {
        if (e == error.ProcExit) {
            setError(ZW_ERR_WASI_EXIT, "guest called proc_exit", .{});
            return ZW_ERR_WASI_EXIT;
        }
        setErrorName(ZW_ERR_TRAP, e);
        return ZW_ERR_TRAP;
    };
    for (res_vals, 0..) |v, i| results[i] = encodeValue(v);
    return ZW_OK;
}

fn outOfMemory() i32 {
    setError(ZW_ERR_INTERNAL, "out of memory", .{});
    return ZW_ERR_INTERNAL;
}

export fn zw_instance_wasi_exit_code(inst_ptr: ?*anyopaque) callconv(.c) i64 {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return -1));
    const code = h.instance.wasiExitCode() orelse return -1;
    return code;
}

// ── instance ───────────────────────────────────────────────────────────────

fn engineKind(code: u8) zwasm.api.instance.EngineKind {
    if (is_wasm) return .interp;
    return switch (code) {
        1 => .jit,
        2 => .interp,
        else => .auto,
    };
}

fn freeHostCtx(hc: *HostCtx) void {
    gpa.free(hc.module_name);
    gpa.free(hc.import_name);
    gpa.free(hc.params);
    gpa.free(hc.results);
    gpa.destroy(hc);
}

fn destroyHostCtxs(list: *std.ArrayList(*HostCtx)) void {
    for (list.items) |hc| freeHostCtx(hc);
    list.deinit(gpa);
}

fn destroyWasiCtxs(list: *std.ArrayList(*WasiFnCtx)) void {
    for (list.items) |ctx| gpa.destroy(ctx);
    list.deinit(gpa);
}

export fn zw_instance_new(
    module_ptr: ?*anyopaque,
    engine_kind: u8,
    fuel: i64,
    max_memory_pages: i64,
    wasi_ptr: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    return zw_instance_new_with_imports(
        module_ptr,
        engine_kind,
        fuel,
        max_memory_pages,
        wasi_ptr,
        null,
        0,
        null,
        null,
    );
}

/// Instantiate with an optional host-import table. `imports` is an array of
/// `n_imports` descriptors; every function import is dispatched through the
/// single `host_cb` with its index. The callback and descriptors are copied
/// into host-owned storage, so Dart/JS may free its staging buffers on return.
///
/// On the web, host imports are not supported yet (the JS bridge cannot pass a
/// wasm function pointer as `ZWHostCallback`); the call fails with
/// ZW_ERR_INVALID_ARG instead of silently binding nothing.
export fn zw_instance_new_with_imports(
    module_ptr: ?*anyopaque,
    engine_kind: u8,
    fuel: i64,
    max_memory_pages: i64,
    wasi_ptr: ?*anyopaque,
    imports: ?[*]const ZWImportDesc,
    n_imports: u32,
    host_ctx: ?*anyopaque,
    host_cb: ?ZWHostCallback,
) callconv(.c) ?*anyopaque {
    clearError();
    const m: *ModuleH = @ptrCast(@alignCast(module_ptr orelse {
        setError(ZW_ERR_INVALID_ARG, "null module", .{});
        return null;
    }));
    const opts: zwasm.Module.InstantiateOpts = .{
        .engine = engineKind(engine_kind),
        .fuel = if (fuel < 0) .unmetered else .{ .limited = @intCast(fuel) },
        .max_memory_pages = if (max_memory_pages < 0) .unmetered else .{ .limited = @intCast(max_memory_pages) },
    };

    const has_imports = n_imports > 0;
    const has_wasi = wasi_ptr != null;
    if (has_imports and host_cb == null and !is_wasm) {
        setError(ZW_ERR_INVALID_ARG, "host callback is required for imports", .{});
        return null;
    }

    var inst: zwasm.Instance = undefined;
    var linker: ?*zwasm.Linker = null;
    var host_ctxs: std.ArrayList(*HostCtx) = .empty;
    var vfs: ?*zwasm.vfs.MemFs = null;
    var wasi_ctxs: std.ArrayList(*WasiFnCtx) = .empty;
    var handed_off = false;
    defer if (!handed_off) {
        if (linker) |lk| {
            lk.deinit();
            gpa.destroy(lk);
        }
        destroyHostCtxs(&host_ctxs);
        destroyWasiCtxs(&wasi_ctxs);
        if (vfs) |fs| {
            fs.deinit();
            gpa.destroy(fs);
        }
    };

    if (has_imports or has_wasi) {
        const lk = gpa.create(zwasm.Linker) catch {
            setError(ZW_ERR_INTERNAL, "out of memory", .{});
            return null;
        };
        lk.* = zwasm.Linker.init(&m.engine.engine);
        linker = lk;
    }

    if (wasi_ptr) |wp| {
        const cfg: *WasiCfgH = @ptrCast(@alignCast(wp));
        const lk = linker.?;
        const has_vfs = cfg.files.items.len > 0 or cfg.dirs.items.len > 0;

        const args = gpa.alloc([]const u8, cfg.args.items.len) catch return outOfMemoryNull();
        defer gpa.free(args);
        for (cfg.args.items, 0..) |a, i| args[i] = a;

        const envs = gpa.alloc(zwasm.WasiConfig.Env, cfg.envs.items.len) catch return outOfMemoryNull();
        defer gpa.free(envs);
        for (cfg.envs.items, 0..) |e, i| envs[i] = .{ .name = e.name, .value = e.value };

        const preopens = gpa.alloc(zwasm.WasiConfig.Preopen, if (has_vfs) 0 else cfg.preopens.items.len) catch return outOfMemoryNull();
        defer gpa.free(preopens);
        if (!has_vfs) {
            for (cfg.preopens.items, 0..) |p, i| preopens[i] = .{ .host_path = p.host, .guest_path = p.guest };
        }

        if (has_vfs) {
            const fs = gpa.create(zwasm.vfs.MemFs) catch return outOfMemoryNull();
            fs.* = zwasm.vfs.MemFs.init(gpa) catch {
                gpa.destroy(fs);
                setError(ZW_ERR_INTERNAL, "out of memory", .{});
                return null;
            };
            vfs = fs;
            for (cfg.dirs.items) |d| {
                fs.addDir(d.path, d.writable) catch |e| {
                    setErrorName(ZW_ERR_INSTANTIATE, e);
                    return null;
                };
            }
            for (cfg.files.items) |f| {
                fs.addFile(f.path, f.data, f.writable) catch |e| {
                    setErrorName(ZW_ERR_INSTANTIATE, e);
                    return null;
                };
            }
        }

        var wasi_cfg: zwasm.WasiConfig = .{ .args = args, .envs = envs, .preopens = preopens };
        if (!has_vfs and preopens.len > 0) {
            if (comptime is_wasm) {
                setError(ZW_ERR_INVALID_ARG, "WASI preopens are not supported on web", .{});
                return null;
            }
            // Preopens only need synchronous open/close/read/write. The
            // global single-threaded io runs those on the calling thread and
            // has no worker pool to outlive the Dart isolate (the engine's
            // Threaded io does, which crashes process teardown on Windows).
            wasi_cfg.io = std.Io.Threaded.global_single_threaded.io();
        }
        lk.defineWasi(wasi_cfg) catch |e| {
            setErrorName(ZW_ERR_INSTANTIATE, e);
            return null;
        };
        if (vfs) |fs| {
            defineWasiFs(lk, fs, &wasi_ctxs) catch |e| {
                setErrorName(ZW_ERR_INSTANTIATE, e);
                return null;
            };
        }
    }

    if (has_imports) {
        const lk = linker.?;
        const descs = imports.?;
        const cb = host_cb;
        for (0..n_imports) |i| {
            const d = descs[i];
            const params = gpa.alloc(zwasm.ir.zir.ValType, d.params_len) catch return outOfMemoryNull();
            for (0..d.params_len) |j| {
                params[j] = scalarValType(d.params[j]) orelse {
                    gpa.free(params);
                    setError(ZW_ERR_INVALID_ARG, "import {d}: unsupported param type {d}", .{ i, d.params[j] });
                    return null;
                };
            }
            const results = gpa.alloc(zwasm.ir.zir.ValType, d.results_len) catch {
                gpa.free(params);
                return outOfMemoryNull();
            };
            for (0..d.results_len) |j| {
                results[j] = scalarValType(d.results[j]) orelse {
                    gpa.free(params);
                    gpa.free(results);
                    setError(ZW_ERR_INVALID_ARG, "import {d}: unsupported result type {d}", .{ i, d.results[j] });
                    return null;
                };
            }
            const hc = gpa.create(HostCtx) catch {
                gpa.free(params);
                gpa.free(results);
                return outOfMemoryNull();
            };
            const mod_name = gpa.dupe(u8, d.module[0..d.module_len]) catch {
                gpa.free(params);
                gpa.free(results);
                gpa.destroy(hc);
                return outOfMemoryNull();
            };
            const imp_name = gpa.dupe(u8, d.name[0..d.name_len]) catch {
                gpa.free(mod_name);
                gpa.free(params);
                gpa.free(results);
                gpa.destroy(hc);
                return outOfMemoryNull();
            };
            hc.* = .{
                .cb = cb,
                .user_ctx = host_ctx,
                .index = @intCast(i),
                .module_name = mod_name,
                .import_name = imp_name,
                .params = params,
                .results = results,
            };
            host_ctxs.append(gpa, hc) catch {
                freeHostCtx(hc);
                return outOfMemoryNull();
            };
            lk.defineFuncRaw(
                hc.module_name,
                hc.import_name,
                hc,
                params,
                results,
                &hostThunk,
            ) catch |e| {
                setErrorName(ZW_ERR_INSTANTIATE, e);
                return null;
            };
        }
    }

    if (linker) |lk| {
        inst = lk.instantiate(&m.module, opts) catch |e| {
            setErrorName(ZW_ERR_INSTANTIATE, e);
            return null;
        };
    } else {
        inst = m.module.instantiate(opts) catch |e| {
            setErrorName(ZW_ERR_INSTANTIATE, e);
            return null;
        };
    }

    const h = gpa.create(InstanceH) catch {
        inst.deinit();
        setError(ZW_ERR_INTERNAL, "out of memory", .{});
        return null;
    };
    h.* = .{
        .instance = inst,
        .module = m,
        .linker = linker,
        .host_ctxs = host_ctxs,
        .vfs = vfs,
        .wasi_ctxs = wasi_ctxs,
    };
    moduleRetain(m);
    handed_off = true;
    return @ptrCast(h);
}

fn outOfMemoryNull() ?*anyopaque {
    setError(ZW_ERR_INTERNAL, "out of memory", .{});
    return null;
}

export fn zw_instance_delete(ptr: ?*anyopaque) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(ptr orelse return));
    h.instance.deinit();
    if (h.linker) |lk| {
        lk.deinit();
        gpa.destroy(lk);
    }
    destroyHostCtxs(&h.host_ctxs);
    destroyWasiCtxs(&h.wasi_ctxs);
    if (h.vfs) |fs| {
        fs.deinit();
        gpa.destroy(fs);
    }
    const m = h.module;
    gpa.destroy(h);
    moduleRelease(m);
}

export fn zw_instance_set_fuel(inst_ptr: ?*anyopaque, fuel: i64) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return));
    h.instance.setFuel(if (fuel < 0) null else @intCast(fuel));
}

export fn zw_instance_fuel_remaining(inst_ptr: ?*anyopaque) callconv(.c) i64 {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return -1));
    return @intCast(h.instance.fuelRemaining() orelse return -1);
}

export fn zw_instance_set_memory_limit(inst_ptr: ?*anyopaque, pages: i64) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return));
    h.instance.setMemoryPagesLimit(if (pages < 0) null else @intCast(pages));
}

export fn zw_instance_interrupt(inst_ptr: ?*anyopaque) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return));
    h.instance.interrupt();
}

export fn zw_instance_clear_interrupt(inst_ptr: ?*anyopaque) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return));
    h.instance.clearInterrupt();
}

// ── memory ─────────────────────────────────────────────────────────────────

export fn zw_instance_memory_size(inst_ptr: ?*anyopaque) callconv(.c) u64 {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return 0));
    const mem = h.instance.memory() orelse return 0;
    return mem.slice().len;
}

export fn zw_instance_memory_pages(inst_ptr: ?*anyopaque) callconv(.c) u32 {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return 0));
    const mem = h.instance.memory() orelse return 0;
    return mem.size();
}

export fn zw_instance_memory_data(inst_ptr: ?*anyopaque) callconv(.c) u64 {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return 0));
    const mem = h.instance.memory() orelse return 0;
    return @intFromPtr(mem.slice().ptr);
}

export fn zw_instance_memory_grow(inst_ptr: ?*anyopaque, delta: u32) callconv(.c) i64 {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return -1));
    const mem = h.instance.memory() orelse return -1;
    const old = mem.grow(delta) orelse return -1;
    return old;
}

/// Copies host bytes into guest memory at `addr`.
export fn zw_instance_memory_write(
    inst_ptr: ?*anyopaque,
    addr: u64,
    buf: [*]const u8,
    len: usize,
) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return arityError("null instance")));
    const mem = h.instance.memory() orelse {
        setError(ZW_ERR_INVALID_ARG, "instance has no memory", .{});
        return ZW_ERR_INVALID_ARG;
    };
    const data = mem.slice();
    if (addr > data.len or len > data.len - @as(usize, @intCast(addr))) {
        setError(ZW_ERR_INVALID_ARG, "memory write out of bounds", .{});
        return ZW_ERR_INVALID_ARG;
    }
    @memcpy(data[@intCast(addr)..][0..len], buf[0..len]);
    return ZW_OK;
}

// ── globals ────────────────────────────────────────────────────────────────

export fn zw_instance_global_info(inst_ptr: ?*anyopaque, name: [*]const u8, name_len: usize, out_kind: *u8, out_mutable: *u8) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return arityError("null instance")));
    const g = h.instance.global(name[0..name_len]) orelse {
        setError(ZW_ERR_NOT_FOUND, "global not found", .{});
        return ZW_ERR_NOT_FOUND;
    };
    out_kind.* = kindOf(g.valtype);
    out_mutable.* = if (g.mutable) 1 else 0;
    return ZW_OK;
}

export fn zw_instance_global_get(inst_ptr: ?*anyopaque, name: [*]const u8, name_len: usize, out_bits: *u64) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return arityError("null instance")));
    const g = h.instance.global(name[0..name_len]) orelse {
        setError(ZW_ERR_NOT_FOUND, "global not found", .{});
        return ZW_ERR_NOT_FOUND;
    };
    out_bits.* = encodeValue(g.get());
    return ZW_OK;
}

/// Export every file under an in-memory VFS mount. Returns the required
/// length; the host calls once with `buf = null` to size, then again with a
/// buffer. Format: u32 count, then { u32 path_len, path, u64 size, bytes }.
export fn zw_instance_export_mount(
    inst_ptr: ?*anyopaque,
    root: [*]const u8,
    root_len: usize,
    buf: ?[*]u8,
    cap: usize,
) callconv(.c) u64 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return 0));
    const fs = h.vfs orelse return 0;
    if (buf) |b| {
        return @intCast(fs.exportRoot(root[0..root_len], b[0..cap]));
    }
    var empty: [0]u8 = .{};
    return @intCast(fs.exportRoot(root[0..root_len], empty[0..0]));
}

/// Replace all files under an in-memory VFS mount from the export format.
export fn zw_instance_import_mount(
    inst_ptr: ?*anyopaque,
    root: [*]const u8,
    root_len: usize,
    buf: [*]const u8,
    len: usize,
) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return ZW_ERR_INVALID_ARG));
    const fs = h.vfs orelse {
        setError(ZW_ERR_INVALID_ARG, "instance has no VFS", .{});
        return ZW_ERR_INVALID_ARG;
    };
    fs.importRoot(root[0..root_len], buf[0..len]) catch |e| {
        setErrorName(ZW_ERR_INVALID_ARG, e);
        return ZW_ERR_INVALID_ARG;
    };
    return ZW_OK;
}

/// Install a write-through callback for VFS file writes. Pass null to clear.
export fn zw_instance_set_vfs_write_callback(
    inst_ptr: ?*anyopaque,
    ctx: ?*anyopaque,
    cb: ?zwasm.vfs.WriteCallback,
) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return));
    if (h.vfs) |fs| fs.setWriteCallback(ctx, cb);
}

export fn zw_instance_global_set(inst_ptr: ?*anyopaque, name: [*]const u8, name_len: usize, bits: u64) callconv(.c) i32 {
    clearError();
    const h: *InstanceH = @ptrCast(@alignCast(inst_ptr orelse return arityError("null instance")));
    const g = h.instance.global(name[0..name_len]) orelse {
        setError(ZW_ERR_NOT_FOUND, "global not found", .{});
        return ZW_ERR_NOT_FOUND;
    };
    g.set(decodeValue(g.valtype, bits)) catch |e| {
        setErrorName(ZW_ERR_GLOBAL, e);
        return ZW_ERR_GLOBAL;
    };
    return ZW_OK;
}

// ── WASI configuration ─────────────────────────────────────────────────────

export fn zw_wasi_config_new() callconv(.c) ?*anyopaque {
    clearError();
    const h = gpa.create(WasiCfgH) catch return null;
    h.* = .{};
    return @ptrCast(h);
}

export fn zw_wasi_config_delete(ptr: ?*anyopaque) callconv(.c) void {
    const h: *WasiCfgH = @ptrCast(@alignCast(ptr orelse return));
    for (h.args.items) |a| gpa.free(a);
    h.args.deinit(gpa);
    for (h.envs.items) |e| {
        gpa.free(e.name);
        gpa.free(e.value);
    }
    h.envs.deinit(gpa);
    for (h.preopens.items) |p| {
        gpa.free(p.host);
        gpa.free(p.guest);
    }
    h.preopens.deinit(gpa);
    for (h.files.items) |f| {
        gpa.free(f.path);
        gpa.free(f.data);
    }
    h.files.deinit(gpa);
    for (h.dirs.items) |d| gpa.free(d.path);
    h.dirs.deinit(gpa);
    gpa.destroy(h);
}

export fn zw_wasi_config_add_arg(ptr: ?*anyopaque, arg: [*]const u8, len: usize) callconv(.c) i32 {
    const h: *WasiCfgH = @ptrCast(@alignCast(ptr orelse return ZW_ERR_INVALID_ARG));
    const dup = gpa.dupe(u8, arg[0..len]) catch return outOfMemory();
    h.args.append(gpa, dup) catch {
        gpa.free(dup);
        return outOfMemory();
    };
    return ZW_OK;
}

export fn zw_wasi_config_add_env(ptr: ?*anyopaque, key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) callconv(.c) i32 {
    const h: *WasiCfgH = @ptrCast(@alignCast(ptr orelse return ZW_ERR_INVALID_ARG));
    const k = gpa.dupe(u8, key[0..key_len]) catch return outOfMemory();
    const v = gpa.dupe(u8, value[0..value_len]) catch {
        gpa.free(k);
        return outOfMemory();
    };
    h.envs.append(gpa, .{ .name = k, .value = v }) catch {
        gpa.free(k);
        gpa.free(v);
        return outOfMemory();
    };
    return ZW_OK;
}

/// The WASI host routes fd 0/1/2 to the embedding process by default.
export fn zw_wasi_config_inherit_stdio(_: ?*anyopaque) callconv(.c) void {}

/// Queue a host directory as a guest preopen (`/path` in the guest). The
/// directory is opened at instantiation; preopens are unsupported on the web.
export fn zw_wasi_config_preopen_dir(
    ptr: ?*anyopaque,
    host: [*]const u8,
    host_len: usize,
    guest: [*]const u8,
    guest_len: usize,
) callconv(.c) i32 {
    const h: *WasiCfgH = @ptrCast(@alignCast(ptr orelse return ZW_ERR_INVALID_ARG));
    if (comptime is_wasm) {
        setError(ZW_ERR_INVALID_ARG, "WASI preopens are not supported on web", .{});
        return ZW_ERR_INVALID_ARG;
    }
    const hp = gpa.dupe(u8, host[0..host_len]) catch return outOfMemory();
    const gp = gpa.dupe(u8, guest[0..guest_len]) catch {
        gpa.free(hp);
        return outOfMemory();
    };
    h.preopens.append(gpa, .{ .host = hp, .guest = gp }) catch {
        gpa.free(hp);
        gpa.free(gp);
        return outOfMemory();
    };
    return ZW_OK;
}

/// Add a file to the in-memory WASI VFS. The host copies both path and data.
/// `writable` only has an effect under /data or /tmp.
export fn zw_wasi_config_add_file(
    ptr: ?*anyopaque,
    path: [*]const u8,
    path_len: usize,
    data: [*]const u8,
    data_len: usize,
    writable: i32,
) callconv(.c) i32 {
    const h: *WasiCfgH = @ptrCast(@alignCast(ptr orelse return ZW_ERR_INVALID_ARG));
    const p = gpa.dupe(u8, path[0..path_len]) catch return outOfMemory();
    const d = gpa.dupe(u8, data[0..data_len]) catch {
        gpa.free(p);
        return outOfMemory();
    };
    h.files.append(gpa, .{ .path = p, .data = d, .writable = writable != 0 }) catch {
        gpa.free(p);
        gpa.free(d);
        return outOfMemory();
    };
    return ZW_OK;
}

/// Add an explicit directory to the in-memory WASI VFS.
export fn zw_wasi_config_add_dir(
    ptr: ?*anyopaque,
    path: [*]const u8,
    path_len: usize,
    writable: i32,
) callconv(.c) i32 {
    const h: *WasiCfgH = @ptrCast(@alignCast(ptr orelse return ZW_ERR_INVALID_ARG));
    const p = gpa.dupe(u8, path[0..path_len]) catch return outOfMemory();
    h.dirs.append(gpa, .{ .path = p, .writable = writable != 0 }) catch {
        gpa.free(p);
        return outOfMemory();
    };
    return ZW_OK;
}
