//! In-memory WASI preview1 filesystem for hitohoshi cartridges.
//!
//! Mounts:
//!   /app  read-only
//!   /data read-write
//!   /tmp  read-write
//!
//! The host populates files/dirs through the plugin config before
//! instantiation. No host path is preopened and no std.Io is involved.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_wasm = builtin.target.cpu.arch.isWasm();

/// Web-only write-through hook; the JS bridge dispatches to Dart.
extern "env" fn zwJsVfsWrite(
    ctx: ?*anyopaque,
    path: [*]const u8,
    path_len: usize,
    offset: u64,
    data: [*]const u8,
    data_len: usize,
) callconv(.c) i32;

pub const RuntimeValue = @import("../runtime/value.zig").Value;

/// Host write-through callback. `path`/`data` are borrowed for the call.
pub const WriteCallback = *const fn (
    ctx: ?*anyopaque,
    path: [*]const u8,
    path_len: usize,
    offset: u64,
    data: [*]const u8,
    data_len: usize,
) callconv(.c) i32;

pub const Errno = enum(u16) {
    success = 0,
    acces = 2,
    badf = 8,
    exist = 20,
    fault = 21,
    inval = 28,
    io = 29,
    isdir = 31,
    nametoolong = 37,
    noent = 44,
    nomem = 48,
    nospc = 51,
    nosys = 52,
    notdir = 54,
    notempty = 55,
    notsup = 58,
    perm = 63,
    rofs = 69,
    spipe = 70,
};

fn e(x: Errno) u16 {
    return @intFromEnum(x);
}

pub const WasiFn = enum {
    fd_write,
    fd_read,
    fd_close,
    fd_seek,
    fd_tell,
    fd_fdstat_get,
    fd_filestat_get,
    fd_filestat_set_size,
    fd_filestat_set_times,
    fd_sync,
    fd_datasync,
    fd_advise,
    fd_allocate,
    fd_fdstat_set_flags,
    fd_prestat_get,
    fd_prestat_dir_name,
    fd_readdir,
    path_open,
    path_filestat_get,
    path_create_directory,
    path_remove_directory,
    path_unlink_file,
    path_rename,
    path_link,
    path_symlink,
    path_readlink,
};

pub const File = struct {
    path: []u8,
    data: []u8,
    writable: bool,
};

pub const Dir = struct {
    path: []u8,
    writable: bool,
};

pub const Mount = struct {
    root: []const u8,
    writable: bool,
    files: std.ArrayList(*File) = .empty,
    dirs: std.ArrayList(*Dir) = .empty,
};

const FdKind = enum { stdin, stdout, stderr, dir, file, closed };

const Resolved = struct { mi: usize, abs: []const u8 };

const Fd = struct {
    kind: FdKind,
    path: []u8 = &.{},
    mount: usize = 0,
    offset: u64 = 0,
    writable: bool = false,
    preopen: bool = false,
};

pub const MemFs = struct {
    alloc: Allocator,
    mounts: std.ArrayList(Mount) = .empty,
    fds: std.ArrayList(Fd) = .empty,
    write_cb: ?WriteCallback = null,
    write_ctx: ?*anyopaque = null,

    pub fn setWriteCallback(self: *MemFs, ctx: ?*anyopaque, cb: ?WriteCallback) void {
        self.write_ctx = ctx;
        self.write_cb = cb;
    }

    pub fn init(alloc: Allocator) !MemFs {
        var fs: MemFs = .{ .alloc = alloc };
        errdefer fs.deinit();
        try fs.mounts.append(alloc, .{ .root = "/app", .writable = false });
        try fs.mounts.append(alloc, .{ .root = "/data", .writable = true });
        try fs.mounts.append(alloc, .{ .root = "/tmp", .writable = true });
        try fs.fds.append(alloc, .{ .kind = .stdin });
        try fs.fds.append(alloc, .{ .kind = .stdout });
        try fs.fds.append(alloc, .{ .kind = .stderr });
        for (fs.mounts.items, 0..) |m, i| {
            try fs.fds.append(alloc, .{
                .kind = .dir,
                .path = try alloc.dupe(u8, m.root),
                .mount = i,
                .writable = m.writable,
                .preopen = true,
            });
        }
        return fs;
    }

    pub fn deinit(self: *MemFs) void {
        for (self.fds.items) |fd| if (fd.path.len > 0) self.alloc.free(fd.path);
        self.fds.deinit(self.alloc);
        for (self.mounts.items) |*m| {
            for (m.files.items) |f| {
                self.alloc.free(f.path);
                self.alloc.free(f.data);
                self.alloc.destroy(f);
            }
            m.files.deinit(self.alloc);
            for (m.dirs.items) |d| {
                self.alloc.free(d.path);
                self.alloc.destroy(d);
            }
            m.dirs.deinit(self.alloc);
        }
        self.mounts.deinit(self.alloc);
    }

    fn mountFor(self: *MemFs, abs: []const u8) ?usize {
        for (self.mounts.items, 0..) |m, i| {
            if (abs.len >= m.root.len and std.mem.startsWith(u8, abs, m.root)) {
                if (abs.len == m.root.len or abs[m.root.len] == '/') return i;
            }
        }
        return null;
    }

    fn findFile(self: *MemFs, mi: usize, abs: []const u8) ?*File {
        for (self.mounts.items[mi].files.items) |f| {
            if (std.mem.eql(u8, f.path, abs)) return f;
        }
        return null;
    }

    fn findDir(self: *MemFs, mi: usize, abs: []const u8) ?*Dir {
        for (self.mounts.items[mi].dirs.items) |d| {
            if (std.mem.eql(u8, d.path, abs)) return d;
        }
        return null;
    }

    fn isDir(self: *MemFs, mi: usize, abs: []const u8) bool {
        if (std.mem.eql(u8, abs, self.mounts.items[mi].root)) return true;
        if (self.findDir(mi, abs) != null) return true;
        // A directory exists implicitly if any file/dir lives below it.
        for (self.mounts.items[mi].files.items) |f| {
            if (f.path.len > abs.len and std.mem.startsWith(u8, f.path, abs) and f.path[abs.len] == '/') return true;
        }
        for (self.mounts.items[mi].dirs.items) |d| {
            if (d.path.len > abs.len and std.mem.startsWith(u8, d.path, abs) and d.path[abs.len] == '/') return true;
        }
        return false;
    }

    fn ensureParents(self: *MemFs, mi: usize, abs: []const u8) !void {
        var i: usize = 1;
        while (i < abs.len) : (i += 1) {
            if (abs[i] != '/') continue;
            const part = abs[0..i];
            if (part.len == 0) continue;
            if (std.mem.eql(u8, part, self.mounts.items[mi].root)) continue;
            if (!self.isDir(mi, part)) {
                const d = try self.alloc.create(Dir);
                errdefer self.alloc.destroy(d);
                d.* = .{ .path = try self.alloc.dupe(u8, part), .writable = self.mounts.items[mi].writable };
                try self.mounts.items[mi].dirs.append(self.alloc, d);
            }
        }
    }

    pub fn addDir(self: *MemFs, path: []const u8, writable: bool) !void {
        const mi = self.mountFor(path) orelse return error.BadPath;
        if (!self.mounts.items[mi].writable and writable) return error.ReadOnly;
        if (self.findDir(mi, path) != null) return;
        try self.ensureParents(mi, path);
        const d = try self.alloc.create(Dir);
        errdefer self.alloc.destroy(d);
        d.* = .{ .path = try self.alloc.dupe(u8, path), .writable = writable };
        try self.mounts.items[mi].dirs.append(self.alloc, d);
    }

    pub fn addFile(self: *MemFs, path: []const u8, data: []const u8, writable: bool) !void {
        const mi = self.mountFor(path) orelse return error.BadPath;
        if (!self.mounts.items[mi].writable and writable) return error.ReadOnly;
        try self.ensureParents(mi, path);
        if (self.findFile(mi, path)) |f| {
            self.alloc.free(f.data);
            f.data = try self.alloc.dupe(u8, data);
            f.writable = writable;
            return;
        }
        const f = try self.alloc.create(File);
        errdefer self.alloc.destroy(f);
        f.* = .{
            .path = try self.alloc.dupe(u8, path),
            .data = try self.alloc.dupe(u8, data),
            .writable = writable,
        };
        try self.mounts.items[mi].files.append(self.alloc, f);
    }

    /// Parse the `exportRoot` format and replace all files under `root`.
    pub fn importRoot(self: *MemFs, root: []const u8, buf: []const u8) !void {
        const mi = self.mountFor(root) orelse return error.BadPath;
        if (!self.mounts.items[mi].writable) return error.ReadOnly;
        if (buf.len < 4) return error.BadFormat;
        const count = std.mem.readInt(u32, buf[0..4], .little);
        var off: usize = 4;
        var i: usize = 0;
        while (i < self.mounts.items[mi].files.items.len) {
            const f = self.mounts.items[mi].files.items[i];
            if (underRoot(f.path, root)) {
                self.alloc.free(f.path);
                self.alloc.free(f.data);
                self.alloc.destroy(f);
                _ = self.mounts.items[mi].files.swapRemove(i);
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < count) : (i += 1) {
            if (off + 4 > buf.len) return error.BadFormat;
            const plen = std.mem.readInt(u32, buf[off..][0..4], .little);
            off += 4;
            if (off + plen > buf.len) return error.BadFormat;
            const path = buf[off..][0..plen];
            off += plen;
            if (off + 8 > buf.len) return error.BadFormat;
            const size = std.mem.readInt(u64, buf[off..][0..8], .little);
            off += 8;
            if (size > buf.len - off) return error.BadFormat;
            const data = buf[off..][0..@intCast(size)];
            off += @intCast(size);
            if (!underRoot(path, root)) return error.BadFormat;
            try self.addFile(path, data, true);
        }
    }

    fn underRoot(path: []const u8, root: []const u8) bool {
        if (!std.mem.startsWith(u8, path, root)) return false;
        return path.len == root.len or (path.len > root.len and path[root.len] == '/');
    }

    /// Serialize every file under `root` as:
    ///   u32 count, then { u32 path_len, path, u64 size, bytes }.
    /// Returns the required length; writes only when `buf` is large enough.
    pub fn exportRoot(self: *MemFs, root: []const u8, buf: []u8) usize {
        const mi = self.mountFor(root) orelse return 0;
        var count: u32 = 0;
        var need: usize = 4;
        for (self.mounts.items[mi].files.items) |f| {
            if (!underRoot(f.path, root)) continue;
            count += 1;
            need += 4 + f.path.len + 8 + f.data.len;
        }
        if (buf.len < need) return need;
        std.mem.writeInt(u32, buf[0..4], count, .little);
        var off: usize = 4;
        for (self.mounts.items[mi].files.items) |f| {
            if (!underRoot(f.path, root)) continue;
            std.mem.writeInt(u32, buf[off..][0..4], @intCast(f.path.len), .little);
            off += 4;
            @memcpy(buf[off..][0..f.path.len], f.path);
            off += f.path.len;
            std.mem.writeInt(u64, buf[off..][0..8], @intCast(f.data.len), .little);
            off += 8;
            @memcpy(buf[off..][0..f.data.len], f.data);
            off += f.data.len;
        }
        return need;
    }

    fn resolve(
        self: *MemFs,
        mem: anytype,
        dirfd: u32,
        ptr: u32,
        len: u32,
        out: *[512]u8,
    ) ?Resolved {
        if (len > out.len - 1) return null;
        const raw = mem.sliceAt(ptr, len) catch return null;
        var base: []const u8 = "";
        const slot = self.translateFd(dirfd) orelse return null;
        if (slot.kind != .dir) return null;
        if (raw.len > 0 and raw[0] == '/') {
            @memcpy(out[0..raw.len], raw);
            base = "";
            out[raw.len] = 0;
            return self.finishResolve(out[0..raw.len]);
        }
        base = slot.path;
        if (base.len + 1 + raw.len > out.len - 1) return null;
        @memcpy(out[0..base.len], base);
        out[base.len] = '/';
        @memcpy(out[base.len + 1 .. base.len + 1 + raw.len], raw);
        return self.finishResolve(out[0 .. base.len + 1 + raw.len]);
    }

    fn finishResolve(self: *MemFs, path: []u8) ?Resolved {
        // Normalize in place: collapse '//', '.', and reject '..'.
        var w: usize = 1;
        var i: usize = 0;
        var seg_start: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (i == path.len or path[i] == '/') {
                const seg = path[seg_start..i];
                if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
                    // skip
                } else if (std.mem.eql(u8, seg, "..")) {
                    return null;
                } else {
                    if (w > 1) {
                        path[w] = '/';
                        w += 1;
                    }
                    const start = w;
                    std.mem.copyForwards(u8, path[w .. w + seg.len], seg);
                    w += seg.len;
                    _ = start;
                }
                seg_start = i + 1;
            }
        }
        if (w == 0) {
            path[0] = '/';
            w = 1;
        }
        const abs = path[0..w];
        const mi = self.mountFor(abs) orelse return null;
        return .{ .mi = mi, .abs = abs };
    }

    fn translateFd(self: *MemFs, fd: u32) ?*Fd {
        if (fd >= self.fds.items.len) return null;
        const slot = &self.fds.items[fd];
        if (slot.kind == .closed) return null;
        return slot;
    }

    fn pushFd(self: *MemFs, spec: Fd) !u32 {
        try self.fds.append(self.alloc, spec);
        return @intCast(self.fds.items.len - 1);
    }

    fn fileSize(slot: *Fd, fs: *MemFs) ?u64 {
        if (slot.kind != .file) return null;
        const f = fs.findFile(slot.mount, slot.path) orelse return null;
        return f.data.len;
    }

    // ── memory helpers ──────────────────────────────────────────────
    fn r32(mem: anytype, off: u32, v: *u32) Errno {
        v.* = mem.read(u32, off) catch return .fault;
        return .success;
    }
    fn w32(mem: anytype, off: u32, v: u32) u16 {
        mem.write(off, v) catch return e(.fault);
        return e(.success);
    }
    fn w64(mem: anytype, off: u32, v: u64) u16 {
        mem.write(off, v) catch return e(.fault);
        return e(.success);
    }

    pub fn dispatch(self: *MemFs, fnc: WasiFn, mem: anytype, args: []const RuntimeValue) u16 {
        return switch (fnc) {
            .fd_write => self.fdWrite(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2), arg32(args, 3)),
            .fd_read => self.fdRead(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2), arg32(args, 3)),
            .fd_close => self.fdClose(arg32(args, 0)),
            .fd_seek => self.fdSeek(mem, arg32(args, 0), arg64(args, 1), arg32(args, 2), arg32(args, 3)),
            .fd_tell => self.fdTell(mem, arg32(args, 0), arg32(args, 1)),
            .fd_fdstat_get => self.fdFdstatGet(mem, arg32(args, 0), arg32(args, 1)),
            .fd_filestat_get => self.fdFilestatGet(mem, arg32(args, 0), arg32(args, 1)),
            .fd_filestat_set_size => self.fdFilestatSetSize(arg32(args, 0), arg64(args, 1)),
            .fd_sync, .fd_datasync, .fd_advise, .fd_allocate, .fd_fdstat_set_flags, .fd_filestat_set_times => e(.success),
            .fd_prestat_get => self.fdPrestatGet(mem, arg32(args, 0), arg32(args, 1)),
            .fd_prestat_dir_name => self.fdPrestatDirName(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2)),
            .fd_readdir => self.fdReaddir(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2), @intCast(arg64(args, 3)), arg32(args, 4)),
            .path_open => self.pathOpen(mem, arg32(args, 0), arg32(args, 2), arg32(args, 3), arg32(args, 4), arg32(args, 8)),
            .path_filestat_get => self.pathFilestatGet(mem, arg32(args, 0), arg32(args, 2), arg32(args, 3), arg32(args, 4)),
            .path_create_directory => self.pathCreateDirectory(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2)),
            .path_remove_directory => self.pathRemoveDirectory(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2)),
            .path_unlink_file => self.pathUnlinkFile(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2)),
            .path_rename => self.pathRename(mem, arg32(args, 0), arg32(args, 1), arg32(args, 2), arg32(args, 3), arg32(args, 4), arg32(args, 5)),
            .path_link, .path_symlink, .path_readlink => e(.notsup),
        };
    }

    fn fdWrite(self: *MemFs, mem: anytype, fd: u32, iovs: u32, n: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        var total: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const off = iovs + i * 8;
            var p: u32 = 0;
            var l: u32 = 0;
            if (r32(mem, off, &p) != .success or r32(mem, off + 4, &l) != .success) return e(.fault);
            const bytes = mem.sliceAt(p, l) catch return e(.fault);
            switch (slot.kind) {
                .stdout, .stderr, .file => {},
                .stdin => return e(.notsup),
                .dir => return e(.isdir),
                .closed => return e(.badf),
            }
            if (slot.kind == .file) {
                if (!slot.writable) return e(.rofs);
                const f = self.findFile(slot.mount, slot.path) orelse return e(.noent);
                const end = slot.offset + l;
                if (end > f.data.len) {
                    const old_len = f.data.len;
                    f.data = self.alloc.realloc(f.data, @intCast(end)) catch return e(.nomem);
                    @memset(f.data[old_len..@intCast(end)], 0);
                }
                @memcpy(f.data[@intCast(slot.offset)..@intCast(end)], bytes);
                slot.offset = end;
                if (self.write_cb) |cb| {
                    const rc = if (comptime is_wasm)
                        zwJsVfsWrite(
                            self.write_ctx,
                            f.path.ptr,
                            f.path.len,
                            slot.offset - l,
                            bytes.ptr,
                            bytes.len,
                        )
                    else
                        cb(
                            self.write_ctx,
                            f.path.ptr,
                            f.path.len,
                            slot.offset - l,
                            bytes.ptr,
                            bytes.len,
                        );
                    if (rc != 0) return e(.io);
                }
            }
            total += l;
        }
        return w32(mem, out, total);
    }

    fn fdRead(self: *MemFs, mem: anytype, fd: u32, iovs: u32, n: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind == .stdin) return w32(mem, out, 0);
        if (slot.kind == .dir) return e(.isdir);
        if (slot.kind != .file) return e(.notsup);
        const f = self.findFile(slot.mount, slot.path) orelse return e(.noent);
        var total: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const off = iovs + i * 8;
            var p: u32 = 0;
            var l: u32 = 0;
            if (r32(mem, off, &p) != .success or r32(mem, off + 4, &l) != .success) return e(.fault);
            if (slot.offset >= f.data.len) break;
            const avail = f.data.len - @as(usize, @intCast(slot.offset));
            const take: u32 = @intCast(@min(@as(usize, l), avail));
            const dst = mem.sliceAt(p, take) catch return e(.fault);
            @memcpy(dst, f.data[@intCast(slot.offset)..][0..take]);
            slot.offset += take;
            total += take;
            if (take < l) break;
        }
        return w32(mem, out, total);
    }

    fn fdClose(self: *MemFs, fd: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind == .stdin or slot.kind == .stdout or slot.kind == .stderr) return e(.success);
        if (slot.path.len > 0) self.alloc.free(slot.path);
        slot.* = .{ .kind = .closed };
        return e(.success);
    }

    fn fdSeek(self: *MemFs, mem: anytype, fd: u32, offset: i64, whence: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind != .file) return e(.spipe);
        const size = fileSize(slot, self) orelse return e(.noent);
        const base: i64 = switch (whence) {
            0 => 0,
            1 => @intCast(slot.offset),
            2 => @intCast(size),
            else => return e(.inval),
        };
        const next = base + offset;
        if (next < 0) return e(.inval);
        slot.offset = @intCast(next);
        return w64(mem, out, slot.offset);
    }

    fn fdTell(self: *MemFs, mem: anytype, fd: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind != .file) return e(.spipe);
        return w64(mem, out, slot.offset);
    }

    fn fdFdstatGet(self: *MemFs, mem: anytype, fd: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        const ft: u8 = switch (slot.kind) {
            .dir => 3,
            .file => 4,
            else => 2,
        };
        mem.write(out, ft) catch return e(.fault);
        mem.write(out + 2, @as(u16, 0)) catch return e(.fault);
        mem.write(out + 8, @as(u64, 0xFFFFFFFFFFFFFFFF)) catch return e(.fault);
        mem.write(out + 16, @as(u64, 0xFFFFFFFFFFFFFFFF)) catch return e(.fault);
        return e(.success);
    }

    fn writeFilestat(mem: anytype, out: u32, ft: u8, size: u64) u16 {
        var zeros: [64]u8 = @splat(0);
        @memcpy(mem.sliceAt(out, 64) catch return e(.fault), &zeros);
        mem.write(out, @as(u64, 0)) catch return e(.fault);
        mem.write(out + 8, @as(u64, 1)) catch return e(.fault);
        mem.write(out + 16, ft) catch return e(.fault);
        mem.write(out + 24, @as(u64, 1)) catch return e(.fault);
        mem.write(out + 32, size) catch return e(.fault);
        return e(.success);
    }

    fn fdFilestatGet(self: *MemFs, mem: anytype, fd: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind == .dir) return writeFilestat(mem, out, 3, 0);
        if (slot.kind != .file) return writeFilestat(mem, out, 2, 0);
        const f = self.findFile(slot.mount, slot.path) orelse return e(.noent);
        return writeFilestat(mem, out, 4, f.data.len);
    }

    fn pathFilestatGet(self: *MemFs, mem: anytype, dirfd: u32, ptr: u32, len: u32, out: u32) u16 {
        var buf: [512]u8 = undefined;
        const r = self.resolve(mem, dirfd, ptr, len, &buf) orelse return e(.noent);
        if (self.findFile(r.mi, r.abs)) |f| return writeFilestat(mem, out, 4, f.data.len);
        if (self.isDir(r.mi, r.abs)) return writeFilestat(mem, out, 3, 0);
        return e(.noent);
    }

    fn fdFilestatSetSize(self: *MemFs, fd: u32, size: i64) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind != .file) return e(.badf);
        if (!slot.writable) return e(.rofs);
        if (size < 0) return e(.inval);
        const f = self.findFile(slot.mount, slot.path) orelse return e(.noent);
        const old = f.data.len;
        f.data = self.alloc.realloc(f.data, @intCast(size)) catch return e(.nomem);
        if (@as(usize, @intCast(size)) > old) @memset(f.data[old..], 0);
        return e(.success);
    }

    fn fdPrestatGet(self: *MemFs, mem: anytype, fd: u32, out: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (!slot.preopen or slot.kind != .dir) return e(.badf);
        mem.write(out, @as(u8, 0)) catch return e(.fault);
        mem.write(out + 1, @as(u8, 0)) catch return e(.fault);
        mem.write(out + 2, @as(u8, 0)) catch return e(.fault);
        mem.write(out + 3, @as(u8, 0)) catch return e(.fault);
        mem.write(out + 4, @as(u32, @intCast(slot.path.len))) catch return e(.fault);
        return e(.success);
    }

    fn fdPrestatDirName(self: *MemFs, mem: anytype, fd: u32, ptr: u32, len: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (!slot.preopen or slot.kind != .dir) return e(.badf);
        if (len < @as(u32, @intCast(slot.path.len))) return e(.nametoolong);
        const dst = mem.sliceAt(ptr, @intCast(slot.path.len)) catch return e(.fault);
        @memcpy(dst, slot.path);
        return e(.success);
    }

    fn fdReaddir(self: *MemFs, mem: anytype, fd: u32, buf: u32, buf_len: u32, cookie: u64, used: u32) u16 {
        const slot = self.translateFd(fd) orelse return e(.badf);
        if (slot.kind != .dir) return e(.notdir);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.alloc);
        const base = slot.path;
        for (self.mounts.items[slot.mount].files.items) |f| {
            if (parentOf(f.path, base)) |n| names.append(self.alloc, n) catch return e(.nomem);
        }
        for (self.mounts.items[slot.mount].dirs.items) |d| {
            if (parentOf(d.path, base)) |n| names.append(self.alloc, n) catch return e(.nomem);
        }
        std.sort.heap([]const u8, names.items, {}, lessThan);
        var written: u32 = 0;
        var idx: u64 = cookie;
        while (idx < names.items.len) : (idx += 1) {
            const nm = names.items[@intCast(idx)];
            const need: u32 = @intCast(24 + nm.len);
            if (written + need > buf_len) break;
            const off = buf + written;
            mem.write(off, idx + 1) catch return e(.fault);
            mem.write(off + 8, idx + 1) catch return e(.fault);
            mem.write(off + 16, @as(u32, @intCast(nm.len))) catch return e(.fault);
            mem.write(off + 20, @as(u8, 4)) catch return e(.fault);
            mem.write(off + 21, @as(u8, 0)) catch return e(.fault);
            mem.write(off + 22, @as(u8, 0)) catch return e(.fault);
            mem.write(off + 23, @as(u8, 0)) catch return e(.fault);
            const dst = mem.sliceAt(off + 24, @intCast(nm.len)) catch return e(.fault);
            @memcpy(dst, nm);
            written += need;
        }
        return w32(mem, used, written);
    }

    fn pathOpen(self: *MemFs, mem: anytype, dirfd: u32, ptr: u32, len: u32, oflags: u32, out: u32) u16 {
        var buf: [512]u8 = undefined;
        const r = self.resolve(mem, dirfd, ptr, len, &buf) orelse return e(.noent);
        const mount = &self.mounts.items[r.mi];
        const directory = (oflags & 2) != 0;
        if (directory) {
            if (!self.isDir(r.mi, r.abs)) {
                if ((oflags & 1) == 0 or !mount.writable) return e(.noent);
                const d = self.alloc.create(Dir) catch return e(.nomem);
                d.* = .{ .path = self.alloc.dupe(u8, r.abs) catch {
                    self.alloc.destroy(d);
                    return e(.nomem);
                }, .writable = true };
                mount.dirs.append(self.alloc, d) catch return e(.nomem);
            }
            const nfd = self.pushFd(.{
                .kind = .dir,
                .path = self.alloc.dupe(u8, r.abs) catch return e(.nomem),
                .mount = r.mi,
                .writable = mount.writable,
            }) catch return e(.nomem);
            return w32(mem, out, nfd);
        }
        var f = self.findFile(r.mi, r.abs);
        if (f == null) {
            if ((oflags & 1) == 0 or !mount.writable) return e(.noent);
            const nf = self.alloc.create(File) catch return e(.nomem);
            nf.* = .{
                .path = self.alloc.dupe(u8, r.abs) catch {
                    self.alloc.destroy(nf);
                    return e(.nomem);
                },
                .data = self.alloc.alloc(u8, 0) catch {
                    self.alloc.free(nf.path);
                    self.alloc.destroy(nf);
                    return e(.nomem);
                },
                .writable = true,
            };
            mount.files.append(self.alloc, nf) catch return e(.nomem);
            f = nf;
        }
        if ((oflags & 8) != 0) {
            if (!mount.writable) return e(.rofs);
            const ff = f.?;
            self.alloc.free(ff.data);
            ff.data = self.alloc.alloc(u8, 0) catch return e(.nomem);
        }
        const nfd = self.pushFd(.{
            .kind = .file,
            .path = self.alloc.dupe(u8, r.abs) catch return e(.nomem),
            .mount = r.mi,
            .writable = mount.writable,
        }) catch return e(.nomem);
        return w32(mem, out, nfd);
    }

    fn pathCreateDirectory(self: *MemFs, mem: anytype, dirfd: u32, ptr: u32, len: u32) u16 {
        var buf: [512]u8 = undefined;
        const r = self.resolve(mem, dirfd, ptr, len, &buf) orelse return e(.noent);
        if (!self.mounts.items[r.mi].writable) return e(.rofs);
        if (self.isDir(r.mi, r.abs)) return e(.exist);
        self.addDir(r.abs, true) catch return e(.io);
        return e(.success);
    }

    fn pathRemoveDirectory(self: *MemFs, mem: anytype, dirfd: u32, ptr: u32, len: u32) u16 {
        var buf: [512]u8 = undefined;
        const r = self.resolve(mem, dirfd, ptr, len, &buf) orelse return e(.noent);
        const mount = &self.mounts.items[r.mi];
        if (!mount.writable) return e(.rofs);
        if (!self.isDir(r.mi, r.abs)) return e(.notdir);
        for (mount.files.items) |f| if (f.path.len > r.abs.len and std.mem.startsWith(u8, f.path, r.abs) and f.path[r.abs.len] == '/') return e(.notempty);
        var i: usize = 0;
        while (i < mount.dirs.items.len) : (i += 1) {
            const d = mount.dirs.items[i];
            if (std.mem.eql(u8, d.path, r.abs)) {
                self.alloc.free(d.path);
                self.alloc.destroy(d);
                _ = mount.dirs.swapRemove(i);
                return e(.success);
            }
        }
        return e(.noent);
    }

    fn pathUnlinkFile(self: *MemFs, mem: anytype, dirfd: u32, ptr: u32, len: u32) u16 {
        var buf: [512]u8 = undefined;
        const r = self.resolve(mem, dirfd, ptr, len, &buf) orelse return e(.noent);
        const mount = &self.mounts.items[r.mi];
        if (!mount.writable) return e(.rofs);
        var i: usize = 0;
        while (i < mount.files.items.len) : (i += 1) {
            const f = mount.files.items[i];
            if (std.mem.eql(u8, f.path, r.abs)) {
                self.alloc.free(f.path);
                self.alloc.free(f.data);
                self.alloc.destroy(f);
                _ = mount.files.swapRemove(i);
                return e(.success);
            }
        }
        return e(.noent);
    }

    fn pathRename(self: *MemFs, mem: anytype, oldfd: u32, oldp: u32, oldl: u32, newfd: u32, newp: u32, newl: u32) u16 {
        var b1: [512]u8 = undefined;
        var b2: [512]u8 = undefined;
        const a = self.resolve(mem, oldfd, oldp, oldl, &b1) orelse return e(.noent);
        const b = self.resolve(mem, newfd, newp, newl, &b2) orelse return e(.noent);
        if (a.mi != b.mi or !self.mounts.items[a.mi].writable) return e(.rofs);
        if (self.findFile(a.mi, a.abs)) |f| {
            self.alloc.free(f.path);
            f.path = self.alloc.dupe(u8, b.abs) catch return e(.nomem);
            return e(.success);
        }
        return e(.noent);
    }
};

fn parentOf(path: []const u8, base: []const u8) ?[]const u8 {
    if (path.len <= base.len + 1) return null;
    if (!std.mem.startsWith(u8, path, base)) return null;
    if (path[base.len] != '/') return null;
    const rest = path[base.len + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return rest;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn arg32(args: []const RuntimeValue, i: usize) u32 {
    return @truncate(args[i].bits64);
}
fn arg64(args: []const RuntimeValue, i: usize) i64 {
    return @bitCast(args[i].bits64);
}
