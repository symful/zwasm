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
    exports: ?zwasm.ModuleExports = null,
    refs: u32 = 1,
};

const InstanceH = struct {
    instance: zwasm.Instance,
    module: *ModuleH,
    refs: u32 = 1,
};

const WasiEnv = struct { name: []u8, value: []u8 };

const WasiCfgH = struct {
    args: std.ArrayList([]u8) = .empty,
    envs: std.ArrayList(WasiEnv) = .empty,
};

fn moduleRetain(m: *ModuleH) void {
    m.refs += 1;
}

fn moduleRelease(m: *ModuleH) void {
    if (m.refs > 1) {
        m.refs -= 1;
        return;
    }
    if (m.exports) |*ex| ex.deinit();
    m.module.deinit();
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
    const mod = eng.engine.compile(bytes[0..len]) catch |e| {
        setErrorName(ZW_ERR_COMPILE, e);
        return null;
    };
    const h = gpa.create(ModuleH) catch {
        setError(ZW_ERR_INTERNAL, "out of memory", .{});
        return null;
    };
    h.* = .{
        .module = mod,
        .engine = eng,
    };
    eng.refs += 1;
    h.exports = mod.exports(gpa) catch null;
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

export fn zw_instance_new(
    module_ptr: ?*anyopaque,
    engine_kind: u8,
    fuel: i64,
    max_memory_pages: i64,
    wasi_ptr: ?*anyopaque,
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

    var inst: zwasm.Instance = undefined;
    if (wasi_ptr) |wp| {
        const cfg: *WasiCfgH = @ptrCast(@alignCast(wp));
        var lk = zwasm.Linker.init(&m.engine.engine);
        defer lk.deinit();
        const args = gpa.alloc([]const u8, cfg.args.items.len) catch return null;
        defer gpa.free(args);
        for (cfg.args.items, 0..) |a, i| args[i] = a;
        const envs = gpa.alloc(zwasm.WasiConfig.Env, cfg.envs.items.len) catch return null;
        defer gpa.free(envs);
        for (cfg.envs.items, 0..) |e, i| envs[i] = .{ .name = e.name, .value = e.value };
        lk.defineWasi(.{ .args = args, .envs = envs }) catch |e| {
            setErrorName(ZW_ERR_INSTANTIATE, e);
            return null;
        };
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
    h.* = .{ .instance = inst, .module = m };
    moduleRetain(m);
    return @ptrCast(h);
}

export fn zw_instance_delete(ptr: ?*anyopaque) callconv(.c) void {
    const h: *InstanceH = @ptrCast(@alignCast(ptr orelse return));
    h.instance.deinit();
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
