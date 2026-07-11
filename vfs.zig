const std = @import("std");
const c = @import("c.zig").c;
const builtin = @import("builtin");

const HMODULE = ?*anyopaque;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) HMODULE;
extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const pending_byte: u64 = 0x40000000;
const reserved_byte: u64 = pending_byte + 1;
const shared_first: u64 = pending_byte + 2;
const shared_size: u64 = 510;
var registry_guard: std.Io.Mutex = .init;
var registry_head: ?*Vfs.File = null;
var barrier_value: u8 = 0;
var win_av_retry_count: i32 = 10;
var win_av_retry_delay_ms: i32 = 25;
var initializing_vfs: ?*c.sqlite3_vfs = null;

const Vfs = @This();

allocator: std.mem.Allocator,
io: std.Io,
root_dir: std.Io.Dir,
value: c.sqlite3_vfs,
name: [:0]u8,
dl_error: [256]u8,
dl_error_len: usize,
dl_error_guard: std.Io.Mutex,
mmap_fetches: usize,

const File = struct {
    const Deferred = struct {
        file: std.Io.File = undefined,
        allocator: std.mem.Allocator,
        next: ?*Deferred = null,
    };

    base: c.sqlite3_file,
    file: std.Io.File,
    vfs: *Vfs,
    delete_on_close: bool,
    lock_level: c_int,
    inode: std.Io.File.INode,
    path: [:0]u8,
    identity: [:0]u8,
    registry_next: ?*File,
    shm_node: ?*ShmNode,
    shm_locks: [c.SQLITE_SHM_NLOCK]u8,
    mmap: ?std.Io.File.MemoryMap,
    mmap_limit: u64,
    fetch_count: usize,
    deferred_node: *Deferred,
    deferred_head: ?*Deferred,
    persist_wal: bool,
    chunk_size: u64,
    powersafe_overwrite: bool,
    open_read_only: u8,

    fn fromBase(base: [*c]c.sqlite3_file) *File {
        return @ptrCast(@alignCast(base));
    }
};

const ShmMapping = struct {
    mapping: std.Io.File.MemoryMap,
    data_offset: usize,
};

const ShmNode = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    file: std.Io.File,
    path: [:0]u8,
    maps: std.ArrayList(ShmMapping) = .empty,
    region_size: usize = 0,
    references: usize = 1,
    read_only: bool,
};

const io_methods: c.sqlite3_io_methods = .{
    .iVersion = 3,
    .xClose = close,
    .xRead = read,
    .xWrite = write,
    .xTruncate = truncate,
    .xSync = sync,
    .xFileSize = fileSize,
    .xLock = lock,
    .xUnlock = unlock,
    .xCheckReservedLock = checkReservedLock,
    .xFileControl = fileControl,
    .xSectorSize = sectorSize,
    .xDeviceCharacteristics = deviceCharacteristics,
    .xShmMap = shmMap,
    .xShmLock = shmLock,
    .xShmBarrier = shmBarrier,
    .xShmUnmap = shmUnmap,
    .xFetch = fetch,
    .xUnfetch = unfetch,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir) !*Vfs {
    const self = try allocator.create(Vfs);
    errdefer allocator.destroy(self);

    const name = try std.fmt.allocPrintSentinel(allocator, "zig-io-{x}", .{@intFromPtr(self)}, 0);
    errdefer allocator.free(name);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
        .value = std.mem.zeroes(c.sqlite3_vfs),
        .name = name,
        .dl_error = undefined,
        .dl_error_len = 0,
        .dl_error_guard = .init,
        .mmap_fetches = 0,
    };
    self.value.iVersion = 2;
    self.value.mxPathname = 4096;
    self.value.pNext = null;
    self.value.zName = name.ptr;
    self.value.szOsFile = @sizeOf(File);
    self.value.xOpen = open;
    self.value.xDelete = delete;
    self.value.xAccess = access;
    self.value.xFullPathname = fullPathname;
    self.value.xDlOpen = dlOpen;
    self.value.xDlError = dlError;
    self.value.xDlSym = dlSym;
    self.value.xDlClose = dlClose;
    self.value.xRandomness = randomness;
    self.value.xSleep = sleep;
    self.value.xCurrentTime = currentTime;
    self.value.xCurrentTimeInt64 = currentTimeInt64;

    initializing_vfs = &self.value;
    defer initializing_vfs = null;
    const result = c.sqlite3_vfs_register(&self.value, 0);
    if (result != c.SQLITE_OK) return error.VfsRegistrationFailed;
    return self;
}

pub fn osInit() c_int {
    const value = initializing_vfs orelse return c.SQLITE_ERROR;
    return c.sqlite3_vfs_register(value, 1);
}

pub fn deinit(self: *Vfs) void {
    _ = c.sqlite3_vfs_unregister(&self.value);
    const allocator = self.allocator;
    allocator.free(self.name);
    allocator.destroy(self);
}

fn fromValue(value: [*c]c.sqlite3_vfs) *Vfs {
    const pointer: *c.sqlite3_vfs = @ptrCast(value);
    return @fieldParentPtr("value", pointer);
}

fn relativePath(self: *Vfs, path: []const u8) ?[]const u8 {
    if (path.len < self.name.len + 2 or path[0] != '/') return path;
    if (!std.mem.eql(u8, path[1 .. self.name.len + 1], self.name)) return null;
    if (path[self.name.len + 1] != '/') return null;
    return path[self.name.len + 2 ..];
}

fn open(value: [*c]c.sqlite3_vfs, z_name: c.sqlite3_filename, base: [*c]c.sqlite3_file, flags: c_int, out_flags: [*c]c_int) callconv(.c) c_int {
    base.*.pMethods = null;
    const self = fromValue(value);
    const path: [:0]u8 = if (z_name == null) temp: {
        var random: [8]u8 = undefined;
        self.io.random(&random);
        break :temp std.fmt.allocPrintSentinel(self.allocator, "zig-sqlite-{x}", .{std.mem.readInt(u64, &random, .little)}, 0) catch return c.SQLITE_CANTOPEN;
    } else self.allocator.dupeSentinel(u8, self.relativePath(std.mem.span(z_name)) orelse return c.SQLITE_CANTOPEN, 0) catch return c.SQLITE_NOMEM;
    const read_write = flags & c.SQLITE_OPEN_READWRITE != 0;
    const create = flags & c.SQLITE_OPEN_CREATE != 0;
    const exclusive = flags & c.SQLITE_OPEN_EXCLUSIVE != 0;
    var actual_flags = flags;
    const file = openFile(self, path, read_write, create, exclusive) catch fallback: {
        if (!read_write or exclusive) {
            self.allocator.free(path);
            return c.SQLITE_CANTOPEN;
        }
        actual_flags &= ~@as(c_int, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE);
        actual_flags |= c.SQLITE_OPEN_READONLY;
        break :fallback self.root_dir.openFile(self.io, path, .{ .mode = .read_only }) catch {
            self.allocator.free(path);
            return c.SQLITE_CANTOPEN;
        };
    };
    var identity_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const identity_len = file.realPath(self.io, &identity_buffer) catch {
        file.close(self.io);
        self.allocator.free(path);
        return c.SQLITE_CANTOPEN_FULLPATH;
    };
    const identity = self.allocator.dupeSentinel(u8, identity_buffer[0..identity_len], 0) catch {
        file.close(self.io);
        self.allocator.free(path);
        return c.SQLITE_NOMEM;
    };
    const deferred_node = self.allocator.create(File.Deferred) catch {
        file.close(self.io);
        self.allocator.free(identity);
        self.allocator.free(path);
        return c.SQLITE_NOMEM;
    };
    deferred_node.* = .{ .allocator = self.allocator };
    const stat = file.stat(self.io) catch {
        self.allocator.destroy(deferred_node);
        file.close(self.io);
        self.allocator.free(identity);
        self.allocator.free(path);
        return c.SQLITE_CANTOPEN;
    };

    const result: *File = @ptrCast(@alignCast(base));
    result.* = .{
        .base = .{ .pMethods = &io_methods },
        .file = file,
        .vfs = self,
        .delete_on_close = flags & c.SQLITE_OPEN_DELETEONCLOSE != 0,
        .lock_level = c.SQLITE_LOCK_NONE,
        .inode = stat.inode,
        .path = path,
        .identity = identity,
        .registry_next = null,
        .shm_node = null,
        .shm_locks = @splat(0),
        .mmap = null,
        .mmap_limit = 0,
        .fetch_count = 0,
        .deferred_node = deferred_node,
        .deferred_head = null,
        .persist_wal = false,
        .chunk_size = 0,
        .powersafe_overwrite = true,
        .open_read_only = @intFromBool(actual_flags & c.SQLITE_OPEN_READONLY != 0),
    };
    registryLock(self.io);
    result.registry_next = registry_head;
    registry_head = result;
    registryUnlock(self.io);
    if (out_flags != null) out_flags.* = actual_flags;
    return c.SQLITE_OK;
}

fn openFile(self: *Vfs, path: []const u8, read_write: bool, create: bool, exclusive: bool) !std.Io.File {
    const mode: std.Io.Dir.OpenFileOptions.Mode = if (read_write) .read_write else .read_only;
    if (!create) return self.root_dir.openFile(self.io, path, .{ .mode = mode });
    if (exclusive) return self.root_dir.createFile(self.io, path, .{ .read = read_write, .truncate = false, .exclusive = true });
    return self.root_dir.openFile(self.io, path, .{ .mode = mode }) catch |err| switch (err) {
        error.FileNotFound => self.root_dir.createFile(self.io, path, .{ .read = read_write, .truncate = false }),
        else => return err,
    };
}

fn close(base: [*c]c.sqlite3_file) callconv(.c) c_int {
    const self = File.fromBase(base);
    unmapDatabase(self);
    _ = shmUnmap(base, 0);
    _ = unlock(base, c.SQLITE_LOCK_NONE);
    registryLock(self.vfs.io);
    var survivor: ?*File = null;
    var current = registry_head;
    while (current) |entry| : (current = entry.registry_next) {
        if (entry != self and sameFile(entry, self)) {
            survivor = entry;
            break;
        }
    }
    var link = &registry_head;
    while (link.*) |entry| {
        if (entry == self) {
            link.* = entry.registry_next;
            break;
        }
        link = &entry.registry_next;
    }
    if (builtin.os.tag != .windows and survivor != null) {
        self.deferred_node.file = self.file;
        self.deferred_node.next = survivor.?.deferred_head;
        survivor.?.deferred_head = self.deferred_node;
        if (self.deferred_head) |head| {
            var last = head;
            while (last.next) |next| last = next;
            last.next = survivor.?.deferred_head;
            survivor.?.deferred_head = head;
        }
    }
    registryUnlock(self.vfs.io);
    if (builtin.os.tag == .windows or survivor == null) {
        self.file.close(self.vfs.io);
        self.vfs.allocator.destroy(self.deferred_node);
        closeDeferred(self);
    }
    if (self.delete_on_close) self.vfs.root_dir.deleteFile(self.vfs.io, self.path) catch {};
    self.vfs.allocator.free(self.identity);
    self.vfs.allocator.free(self.path);
    self.base.pMethods = null;
    return c.SQLITE_OK;
}

fn closeDeferred(file: *File) void {
    var current = file.deferred_head;
    while (current) |node| {
        const next = node.next;
        node.file.close(file.vfs.io);
        node.allocator.destroy(node);
        current = next;
    }
    file.deferred_head = null;
}

fn read(base: [*c]c.sqlite3_file, destination: ?*anyopaque, amount: c_int, offset: c.sqlite3_int64) callconv(.c) c_int {
    if (amount < 0 or offset < 0 or destination == null) return c.SQLITE_IOERR_READ;
    const bytes: [*]u8 = @ptrCast(destination.?);
    const buffer = bytes[0..@intCast(amount)];
    const file = File.fromBase(base);
    var retries: u32 = 0;
    const count = while (true) {
        break file.file.readPositionalAll(file.vfs.io, buffer, @intCast(offset)) catch |err| {
            if (retryWindowsIo(file.vfs, err, &retries)) continue;
            return c.SQLITE_IOERR_READ;
        };
    };
    if (count != buffer.len) {
        @memset(buffer[count..], 0);
        return c.SQLITE_IOERR_SHORT_READ;
    }
    return c.SQLITE_OK;
}

fn write(base: [*c]c.sqlite3_file, source: ?*const anyopaque, amount: c_int, offset: c.sqlite3_int64) callconv(.c) c_int {
    if (amount < 0 or offset < 0 or source == null) return c.SQLITE_IOERR_WRITE;
    const bytes: [*]const u8 = @ptrCast(source.?);
    const file = File.fromBase(base);
    var retries: u32 = 0;
    while (true) {
        file.file.writePositionalAll(file.vfs.io, bytes[0..@intCast(amount)], @intCast(offset)) catch |err| {
            if (retryWindowsIo(file.vfs, err, &retries)) continue;
            return c.SQLITE_IOERR_WRITE;
        };
        break;
    }
    return c.SQLITE_OK;
}

fn truncate(base: [*c]c.sqlite3_file, size: c.sqlite3_int64) callconv(.c) c_int {
    if (size < 0) return c.SQLITE_IOERR_TRUNCATE;
    const file = File.fromBase(base);
    if (file.fetch_count == 0) unmapDatabase(file);
    var new_size: u64 = @intCast(size);
    if (file.chunk_size > 0) {
        new_size = alignSize(new_size, file.chunk_size) orelse return c.SQLITE_IOERR_TRUNCATE;
    }
    file.file.setLength(file.vfs.io, new_size) catch return c.SQLITE_IOERR_TRUNCATE;
    return c.SQLITE_OK;
}

fn sync(base: [*c]c.sqlite3_file, flags: c_int) callconv(.c) c_int {
    const file = File.fromBase(base);
    if (builtin.os.tag == .macos and flags & 0x0f == c.SQLITE_SYNC_FULL) {
        while (true) switch (std.posix.errno(std.posix.system.fcntl(file.file.handle, std.posix.F.FULLFSYNC))) {
            .SUCCESS => return c.SQLITE_OK,
            .INTR => continue,
            else => return c.SQLITE_IOERR_FSYNC,
        };
    }
    file.file.sync(file.vfs.io) catch return c.SQLITE_IOERR_FSYNC;
    return c.SQLITE_OK;
}

fn fileSize(base: [*c]c.sqlite3_file, size: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const file = File.fromBase(base);
    const stat = file.file.stat(file.vfs.io) catch return c.SQLITE_IOERR_FSTAT;
    size.* = @intCast(stat.size);
    return c.SQLITE_OK;
}

fn lock(base: [*c]c.sqlite3_file, requested: c_int) callconv(.c) c_int {
    const file = File.fromBase(base);
    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);
    if (requested <= file.lock_level) return c.SQLITE_OK;
    if (localLockConflict(file, requested)) return c.SQLITE_BUSY;

    if (file.lock_level == c.SQLITE_LOCK_NONE) {
        const pending_result = rangeLock(file.file, .shared, pending_byte, 1);
        if (pending_result != .acquired) return if (pending_result == .busy) c.SQLITE_BUSY else c.SQLITE_IOERR_LOCK;
        const shared_result = rangeLock(file.file, .shared, shared_first, shared_size);
        if (shared_result != .acquired) {
            unlockRange(file.file, pending_byte, 1);
            return if (shared_result == .busy) c.SQLITE_BUSY else c.SQLITE_IOERR_LOCK;
        }
        unlockRange(file.file, pending_byte, 1);
        file.lock_level = c.SQLITE_LOCK_SHARED;
    }
    if (requested == c.SQLITE_LOCK_SHARED) return c.SQLITE_OK;

    if (requested >= c.SQLITE_LOCK_RESERVED and file.lock_level < c.SQLITE_LOCK_RESERVED) {
        const reserved_result = rangeLock(file.file, .exclusive, reserved_byte, 1);
        if (reserved_result != .acquired) return if (reserved_result == .busy) c.SQLITE_BUSY else c.SQLITE_IOERR_LOCK;
        file.lock_level = c.SQLITE_LOCK_RESERVED;
    }
    if (requested == c.SQLITE_LOCK_RESERVED) return c.SQLITE_OK;

    if (file.lock_level < c.SQLITE_LOCK_PENDING) {
        const pending_result = rangeLock(file.file, .exclusive, pending_byte, 1);
        if (pending_result != .acquired) return if (pending_result == .busy) c.SQLITE_BUSY else c.SQLITE_IOERR_LOCK;
        file.lock_level = c.SQLITE_LOCK_PENDING;
    }
    if (requested == c.SQLITE_LOCK_PENDING) return c.SQLITE_OK;

    if (builtin.os.tag == .windows) unlockRange(file.file, shared_first, shared_size);
    const exclusive_result = rangeLock(file.file, .exclusive, shared_first, shared_size);
    if (exclusive_result != .acquired) {
        if (builtin.os.tag == .windows and rangeLock(file.file, .shared, shared_first, shared_size) != .acquired) {
            unlockRange(file.file, pending_byte, 1);
            unlockRange(file.file, reserved_byte, 1);
            file.lock_level = c.SQLITE_LOCK_NONE;
            return c.SQLITE_IOERR_LOCK;
        }
        return if (exclusive_result == .busy) c.SQLITE_BUSY else c.SQLITE_IOERR_LOCK;
    }
    file.lock_level = c.SQLITE_LOCK_EXCLUSIVE;
    return c.SQLITE_OK;
}

fn unlock(base: [*c]c.sqlite3_file, requested: c_int) callconv(.c) c_int {
    const file = File.fromBase(base);
    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);
    if (requested >= file.lock_level) return c.SQLITE_OK;

    if (file.lock_level >= c.SQLITE_LOCK_EXCLUSIVE) {
        unlockRange(file.file, shared_first, shared_size);
        if (requested >= c.SQLITE_LOCK_SHARED and !tryRangeLock(file.file, .shared, shared_first, shared_size)) return c.SQLITE_IOERR_UNLOCK;
    }
    if (file.lock_level >= c.SQLITE_LOCK_RESERVED and requested < c.SQLITE_LOCK_RESERVED) unlockRange(file.file, reserved_byte, 1);
    if (file.lock_level >= c.SQLITE_LOCK_PENDING and requested < c.SQLITE_LOCK_PENDING) unlockRange(file.file, pending_byte, 1);
    if (requested == c.SQLITE_LOCK_NONE) {
        if (builtin.os.tag == .windows or !otherLockOwner(file, c.SQLITE_LOCK_SHARED)) unlockRange(file.file, shared_first, shared_size);
    }
    file.lock_level = requested;
    return c.SQLITE_OK;
}

fn otherLockOwner(file: *File, minimum: c_int) bool {
    var current = registry_head;
    while (current) |entry| : (current = entry.registry_next) {
        if (entry != file and sameFile(entry, file) and entry.lock_level >= minimum) return true;
    }
    return false;
}

fn checkReservedLock(base: [*c]c.sqlite3_file, result: [*c]c_int) callconv(.c) c_int {
    const file = File.fromBase(base);
    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);
    if (file.lock_level >= c.SQLITE_LOCK_RESERVED) {
        result.* = 1;
        return c.SQLITE_OK;
    }
    var current = registry_head;
    while (current) |entry| : (current = entry.registry_next) {
        if (entry != file and sameFile(entry, file) and entry.lock_level >= c.SQLITE_LOCK_RESERVED) {
            result.* = 1;
            return c.SQLITE_OK;
        }
    }
    const available = tryRangeLock(file.file, .exclusive, reserved_byte, 1);
    if (available) unlockRange(file.file, reserved_byte, 1);
    result.* = if (available) 0 else 1;
    return c.SQLITE_OK;
}

const RangeLock = enum { shared, exclusive };
const RangeLockResult = enum { acquired, busy, failed };

fn registryLock(io: std.Io) void {
    registry_guard.lockUncancelable(io);
}

fn registryUnlock(io: std.Io) void {
    registry_guard.unlock(io);
}

fn localLockConflict(file: *File, requested: c_int) bool {
    var current = registry_head;
    while (current) |entry| : (current = entry.registry_next) {
        if (entry == file or !sameFile(entry, file)) continue;
        if (requested == c.SQLITE_LOCK_SHARED) {
            if (entry.lock_level >= c.SQLITE_LOCK_PENDING) return true;
        } else if (requested == c.SQLITE_LOCK_RESERVED) {
            if (entry.lock_level >= c.SQLITE_LOCK_RESERVED) return true;
        } else if (requested >= c.SQLITE_LOCK_PENDING) {
            if (entry.lock_level >= c.SQLITE_LOCK_RESERVED) return true;
            if (requested == c.SQLITE_LOCK_EXCLUSIVE and entry.lock_level >= c.SQLITE_LOCK_SHARED) return true;
        }
    }
    return false;
}

fn sameFile(a: *File, b: *File) bool {
    return std.mem.eql(u8, a.identity, b.identity);
}

fn tryRangeLock(file: std.Io.File, mode: RangeLock, start: u64, len: u64) bool {
    return rangeLock(file, mode, start, len) == .acquired;
}

fn rangeLock(file: std.Io.File, mode: RangeLock, start: u64, len: u64) RangeLockResult {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var status_block: windows.IO_STATUS_BLOCK = undefined;
        const offset: windows.LARGE_INTEGER = @intCast(start);
        const length: windows.LARGE_INTEGER = @intCast(len);
        while (true) switch (windows.ntdll.NtLockFile(
            file.handle,
            null,
            null,
            null,
            &status_block,
            &offset,
            &length,
            null,
            .TRUE,
            .fromBool(mode == .exclusive),
        )) {
            .SUCCESS => return .acquired,
            .LOCK_NOT_GRANTED => return .busy,
            .CANCELLED => continue,
            else => return .failed,
        };
    }
    if (builtin.os.tag == .wasi) return .failed;

    var flock: std.posix.Flock = std.mem.zeroes(std.posix.Flock);
    flock.type = if (mode == .shared) @as(i16, @intCast(std.posix.F.RDLCK)) else @as(i16, @intCast(std.posix.F.WRLCK));
    flock.whence = 0;
    flock.start = @intCast(start);
    flock.len = @intCast(len);
    while (true) switch (std.posix.errno(std.posix.system.fcntl(file.handle, std.posix.F.SETLK, @intFromPtr(&flock)))) {
        .SUCCESS => return .acquired,
        .INTR => continue,
        .AGAIN, .ACCES => return .busy,
        else => return .failed,
    };
}

fn unlockRange(file: std.Io.File, start: u64, len: u64) void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var status_block: windows.IO_STATUS_BLOCK = undefined;
        const offset: windows.LARGE_INTEGER = @intCast(start);
        const length: windows.LARGE_INTEGER = @intCast(len);
        while (windows.ntdll.NtUnlockFile(file.handle, &status_block, &offset, &length, 0) == .CANCELLED) {}
        return;
    }
    if (builtin.os.tag == .wasi) return;

    var flock: std.posix.Flock = std.mem.zeroes(std.posix.Flock);
    flock.type = @intCast(std.posix.F.UNLCK);
    flock.whence = 0;
    flock.start = @intCast(start);
    flock.len = @intCast(len);
    while (std.posix.errno(std.posix.system.fcntl(file.handle, std.posix.F.SETLK, @intFromPtr(&flock))) == .INTR) {}
}

fn ensureShm(file: *File) !*ShmNode {
    if (file.shm_node) |node| return node;
    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);

    var current = registry_head;
    while (current) |entry| : (current = entry.registry_next) {
        if (entry != file and sameFile(entry, file) and entry.shm_node != null) {
            entry.shm_node.?.references += 1;
            file.shm_node = entry.shm_node;
            return entry.shm_node.?;
        }
    }

    const path = try std.fmt.allocPrintSentinel(file.vfs.allocator, "{s}-shm", .{file.path}, 0);
    errdefer file.vfs.allocator.free(path);
    var read_only = file.open_read_only != 0;
    const shm_file = if (read_only)
        try file.vfs.root_dir.openFile(file.vfs.io, path, .{ .mode = .read_only })
    else
        file.vfs.root_dir.openFile(file.vfs.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try file.vfs.root_dir.createFile(file.vfs.io, path, .{ .read = true, .truncate = false }),
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => read_only_fallback: {
                read_only = true;
                break :read_only_fallback try file.vfs.root_dir.openFile(file.vfs.io, path, .{ .mode = .read_only });
            },
            else => return err,
        };
    errdefer shm_file.close(file.vfs.io);

    if (!read_only and tryRangeLock(shm_file, .exclusive, 128, 1)) {
        try shm_file.setLength(file.vfs.io, 3);
        unlockRange(shm_file, 128, 1);
    }
    if (!tryRangeLock(shm_file, .shared, 128, 1)) return error.WouldBlock;

    const node = try file.vfs.allocator.create(ShmNode);
    node.* = .{
        .allocator = file.vfs.allocator,
        .io = file.vfs.io,
        .root_dir = file.vfs.root_dir,
        .file = shm_file,
        .path = path,
        .read_only = read_only,
    };
    file.shm_node = node;
    return node;
}

fn shmMap(base: [*c]c.sqlite3_file, page: c_int, page_size: c_int, extend: c_int, result: [*c]?*volatile anyopaque) callconv(.c) c_int {
    result.* = null;
    if (page < 0 or page_size <= 0) return c.SQLITE_IOERR_SHMMAP;
    const file = File.fromBase(base);
    const index: usize = @intCast(page);
    const len: usize = @intCast(page_size);
    const node = ensureShm(file) catch return if (file.open_read_only != 0) c.SQLITE_READONLY_CANTINIT else c.SQLITE_IOERR_SHMOPEN;
    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);
    if (node.region_size != 0 and node.region_size != len) return c.SQLITE_IOERR_SHMMAP;
    if (index < node.maps.items.len) {
        const mapped = &node.maps.items[index];
        result.* = @ptrCast(mapped.mapping.memory.ptr + mapped.data_offset);
        return if (node.read_only) c.SQLITE_READONLY else c.SQLITE_OK;
    }
    node.region_size = len;

    const required = std.math.mul(usize, index + 1, len) catch return c.SQLITE_IOERR_SHMSIZE;
    const stat = node.file.stat(node.io) catch return c.SQLITE_IOERR_SHMSIZE;
    if (required > stat.size) {
        if (extend == 0) return c.SQLITE_OK;
        if (node.read_only) return c.SQLITE_READONLY_CANTINIT;
        node.file.setLength(node.io, required) catch return c.SQLITE_IOERR_SHMSIZE;
        const system_page_size = std.heap.pageSize();
        const first_new_byte = std.math.add(u64, stat.size, 1) catch return c.SQLITE_IOERR_SHMSIZE;
        var page_end = alignSize(first_new_byte, system_page_size) orelse return c.SQLITE_IOERR_SHMSIZE;
        const zero = [1]u8{0};
        while (page_end <= required) : (page_end += system_page_size) {
            node.file.writePositionalAll(node.io, &zero, page_end - 1) catch return c.SQLITE_IOERR_SHMSIZE;
            if (required - page_end < system_page_size) break;
        }
        if (required % system_page_size != 0) node.file.writePositionalAll(node.io, &zero, required - 1) catch return c.SQLITE_IOERR_SHMSIZE;
    }
    while (node.maps.items.len <= index) {
        const map_index = node.maps.items.len;
        const map_offset = std.math.mul(usize, map_index, len) catch return c.SQLITE_IOERR_SHMMAP;
        const map_end = std.math.add(usize, map_offset, len) catch return c.SQLITE_IOERR_SHMMAP;
        if (map_end > stat.size and extend == 0) return c.SQLITE_OK;
        const allocation_granularity: usize = if (builtin.os.tag == .windows) 64 * 1024 else std.heap.pageSize();
        const aligned_offset = map_offset - map_offset % allocation_granularity;
        const data_offset = map_offset - aligned_offset;
        const mapping = std.Io.File.MemoryMap.create(node.io, node.file, .{
            .len = len + data_offset,
            .offset = aligned_offset,
            .protection = .{ .read = true, .write = !node.read_only },
            .populate = builtin.os.tag == .windows,
        }) catch return c.SQLITE_IOERR_SHMMAP;
        node.maps.append(node.allocator, .{ .mapping = mapping, .data_offset = data_offset }) catch {
            var doomed = mapping;
            doomed.destroy(node.io);
            return c.SQLITE_NOMEM;
        };
    }
    const mapped = &node.maps.items[index];
    result.* = @ptrCast(mapped.mapping.memory.ptr + mapped.data_offset);
    return if (node.read_only) c.SQLITE_READONLY else c.SQLITE_OK;
}

fn shmLock(base: [*c]c.sqlite3_file, offset: c_int, count: c_int, flags: c_int) callconv(.c) c_int {
    if (offset < 0 or count <= 0 or offset + count > c.SQLITE_SHM_NLOCK) return c.SQLITE_IOERR_SHMLOCK;
    const file = File.fromBase(base);
    const node = ensureShm(file) catch return if (file.open_read_only != 0) c.SQLITE_READONLY_CANTINIT else c.SQLITE_IOERR_SHMOPEN;
    const first: usize = @intCast(offset);
    const end: usize = @intCast(offset + count);
    const unlocking = flags & c.SQLITE_SHM_UNLOCK != 0;
    const exclusive = flags & c.SQLITE_SHM_EXCLUSIVE != 0;

    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);
    if (!unlocking) {
        var current = registry_head;
        while (current) |entry| : (current = entry.registry_next) {
            if (entry == file or !sameFile(entry, file)) continue;
            for (first..end) |slot| {
                if (exclusive and entry.shm_locks[slot] != 0) return c.SQLITE_BUSY;
                if (!exclusive and entry.shm_locks[slot] == 2) return c.SQLITE_BUSY;
            }
        }
        for (first..end) |slot| {
            const lock_result = rangeLock(node.file, if (exclusive) .exclusive else .shared, 120 + slot, 1);
            if (lock_result != .acquired) {
                for (first..slot) |acquired| {
                    if (builtin.os.tag == .windows or !otherShmOwner(file, acquired)) unlockRange(node.file, 120 + acquired, 1);
                    file.shm_locks[acquired] = 0;
                }
                return if (lock_result == .busy) c.SQLITE_BUSY else c.SQLITE_IOERR_SHMLOCK;
            }
            file.shm_locks[slot] = if (exclusive) 2 else 1;
        }
    } else {
        for (first..end) |slot| {
            if (builtin.os.tag == .windows or !otherShmOwner(file, slot)) unlockRange(node.file, 120 + slot, 1);
            file.shm_locks[slot] = 0;
        }
    }
    return c.SQLITE_OK;
}

fn shmBarrier(_: [*c]c.sqlite3_file) callconv(.c) void {
    _ = @atomicRmw(u8, &barrier_value, .Add, 0, .seq_cst);
}

fn shmUnmap(base: [*c]c.sqlite3_file, delete_flag: c_int) callconv(.c) c_int {
    const file = File.fromBase(base);
    const node = file.shm_node orelse return c.SQLITE_OK;
    registryLock(file.vfs.io);
    defer registryUnlock(file.vfs.io);
    for (0..file.shm_locks.len) |slot| {
        if (file.shm_locks[slot] != 0 and (builtin.os.tag == .windows or !otherShmOwner(file, slot))) unlockRange(node.file, 120 + slot, 1);
        file.shm_locks[slot] = 0;
    }
    file.shm_node = null;
    node.references -= 1;
    if (node.references == 0) {
        for (node.maps.items) |*mapping| mapping.mapping.destroy(node.io);
        node.maps.deinit(node.allocator);
        unlockRange(node.file, 128, 1);
        const may_delete = tryRangeLock(node.file, .exclusive, 128, 1);
        if (may_delete) unlockRange(node.file, 128, 1);
        node.file.close(node.io);
        if (delete_flag != 0 and !file.persist_wal and may_delete and !node.read_only) node.root_dir.deleteFile(node.io, node.path) catch {};
        const allocator = node.allocator;
        allocator.free(node.path);
        allocator.destroy(node);
    }
    return c.SQLITE_OK;
}

fn otherShmOwner(file: *File, slot: usize) bool {
    var current = registry_head;
    while (current) |entry| : (current = entry.registry_next) {
        if (entry != file and sameFile(entry, file) and entry.shm_locks[slot] != 0) return true;
    }
    return false;
}

fn fetch(base: [*c]c.sqlite3_file, offset: c.sqlite3_int64, amount: c_int, result: [*c]?*anyopaque) callconv(.c) c_int {
    result.* = null;
    if (offset < 0 or amount <= 0) return c.SQLITE_OK;
    const file = File.fromBase(base);
    if (file.mmap_limit == 0) return c.SQLITE_OK;

    if (file.mmap == null) {
        const stat = file.file.stat(file.vfs.io) catch return c.SQLITE_IOERR_FSTAT;
        const map_len_u64 = @min(stat.size, file.mmap_limit);
        if (map_len_u64 == 0 or map_len_u64 > std.math.maxInt(usize)) return c.SQLITE_OK;
        var mapping = std.Io.File.MemoryMap.create(file.vfs.io, file.file, .{
            .len = @intCast(map_len_u64),
            .protection = .{ .read = true },
            .populate = builtin.os.tag == .windows,
        }) catch return c.SQLITE_OK;
        if (mapping.section == null) {
            mapping.destroy(file.vfs.io);
            return c.SQLITE_OK;
        }
        file.mmap = mapping;
    }

    const start: usize = @intCast(offset);
    const len: usize = @intCast(amount);
    const requested_end = std.math.add(usize, start, len) catch return c.SQLITE_OK;
    const safe_end = std.math.add(usize, requested_end, 256) catch return c.SQLITE_OK;
    if (safe_end > file.mmap.?.memory.len) return c.SQLITE_OK;
    result.* = @ptrCast(file.mmap.?.memory.ptr + start);
    file.fetch_count += 1;
    _ = @atomicRmw(usize, &file.vfs.mmap_fetches, .Add, 1, .monotonic);
    return c.SQLITE_OK;
}

fn unfetch(base: [*c]c.sqlite3_file, _: c.sqlite3_int64, pointer: ?*anyopaque) callconv(.c) c_int {
    const file = File.fromBase(base);
    if (pointer != null) {
        if (file.fetch_count > 0) file.fetch_count -= 1;
    } else if (file.fetch_count == 0) {
        unmapDatabase(file);
    }
    return c.SQLITE_OK;
}

fn unmapDatabase(file: *File) void {
    if (file.mmap) |*mapping| mapping.destroy(file.vfs.io);
    file.mmap = null;
}

fn fileControl(base: [*c]c.sqlite3_file, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    const file = File.fromBase(base);
    if (operation == c.SQLITE_FCNTL_LOCKSTATE and argument != null) {
        const lock_level: *c_int = @ptrCast(@alignCast(argument.?));
        lock_level.* = file.lock_level;
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_VFS_POINTER and argument != null) {
        const vfs: *?*c.sqlite3_vfs = @ptrCast(@alignCast(argument.?));
        vfs.* = &file.vfs.value;
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_PERSIST_WAL and argument != null) {
        const persist: *c_int = @ptrCast(@alignCast(argument.?));
        if (persist.* >= 0) file.persist_wal = persist.* != 0;
        persist.* = @intFromBool(file.persist_wal);
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_POWERSAFE_OVERWRITE and argument != null) {
        const enabled: *c_int = @ptrCast(@alignCast(argument.?));
        if (enabled.* >= 0) file.powersafe_overwrite = enabled.* != 0;
        enabled.* = @intFromBool(file.powersafe_overwrite);
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_CHUNK_SIZE and argument != null) {
        const chunk_size: *c_int = @ptrCast(@alignCast(argument.?));
        file.chunk_size = if (chunk_size.* > 0) @intCast(chunk_size.*) else 0;
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_SIZE_HINT and argument != null) {
        if (file.chunk_size == 0) return c.SQLITE_OK;
        const hint: *c.sqlite3_int64 = @ptrCast(@alignCast(argument.?));
        if (hint.* <= 0) return c.SQLITE_OK;
        const requested = alignSize(@intCast(hint.*), file.chunk_size) orelse return c.SQLITE_IOERR_TRUNCATE;
        const stat = file.file.stat(file.vfs.io) catch return c.SQLITE_IOERR_FSTAT;
        if (requested > stat.size) file.file.setLength(file.vfs.io, requested) catch return c.SQLITE_IOERR_TRUNCATE;
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_HAS_MOVED and argument != null) {
        const moved: *c_int = @ptrCast(@alignCast(argument.?));
        const stat = file.vfs.root_dir.statFile(file.vfs.io, file.path, .{}) catch {
            moved.* = 1;
            return c.SQLITE_OK;
        };
        moved.* = @intFromBool(stat.inode != file.inode);
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_VFSNAME and argument != null) {
        const result: *[*c]u8 = @ptrCast(@alignCast(argument.?));
        result.* = c.sqlite3_mprintf("%s", file.vfs.name.ptr);
        return if (result.* == null) c.SQLITE_NOMEM else c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_WIN32_GET_HANDLE and argument != null and builtin.os.tag == .windows) {
        const handle: *std.os.windows.HANDLE = @ptrCast(@alignCast(argument.?));
        handle.* = file.file.handle;
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_WIN32_AV_RETRY and argument != null and builtin.os.tag == .windows) {
        const settings: [*]c_int = @ptrCast(@alignCast(argument.?));
        if (settings[0] > 0) {
            @atomicStore(i32, &win_av_retry_count, settings[0], .release);
        } else {
            settings[0] = @atomicLoad(i32, &win_av_retry_count, .acquire);
        }
        if (settings[1] > 0) {
            @atomicStore(i32, &win_av_retry_delay_ms, settings[1], .release);
        } else {
            settings[1] = @atomicLoad(i32, &win_av_retry_delay_ms, .acquire);
        }
        return c.SQLITE_OK;
    }
    if (operation == c.SQLITE_FCNTL_MMAP_SIZE and argument != null) {
        const limit: *c.sqlite3_int64 = @ptrCast(@alignCast(argument.?));
        const old_limit = file.mmap_limit;
        if (limit.* >= 0) {
            file.mmap_limit = @min(@as(u64, @intCast(limit.*)), std.math.maxInt(usize));
            if (file.fetch_count == 0) unmapDatabase(file);
        }
        limit.* = @intCast(@min(old_limit, std.math.maxInt(c.sqlite3_int64)));
        return c.SQLITE_OK;
    }
    return c.SQLITE_NOTFOUND;
}

fn alignSize(value: u64, alignment: u64) ?u64 {
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return std.math.add(u64, value, alignment - remainder) catch null;
}

fn sectorSize(base: [*c]c.sqlite3_file) callconv(.c) c_int {
    const file = File.fromBase(base);
    const stat = file.file.stat(file.vfs.io) catch return 4096;
    const block_size = stat.block_size;
    if (block_size < 512 or block_size % 512 != 0 or block_size > std.math.maxInt(c_int)) return 4096;
    return @intCast(block_size);
}

fn deviceCharacteristics(base: [*c]c.sqlite3_file) callconv(.c) c_int {
    const file = File.fromBase(base);
    return c.SQLITE_IOCAP_SUBPAGE_READ |
        (if (file.powersafe_overwrite) c.SQLITE_IOCAP_POWERSAFE_OVERWRITE else 0);
}

fn delete(value: [*c]c.sqlite3_vfs, z_name: [*c]const u8, sync_dir: c_int) callconv(.c) c_int {
    const self = fromValue(value);
    const path = self.relativePath(std.mem.span(z_name)) orelse return c.SQLITE_IOERR_DELETE;
    var retries: u32 = 0;
    while (true) {
        self.root_dir.deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => return c.SQLITE_OK,
            else => {
                if (retryWindowsIo(self, err, &retries)) continue;
                return c.SQLITE_IOERR_DELETE;
            },
        };
        break;
    }
    if (sync_dir != 0) {
        if (std.fs.path.dirname(path)) |parent_path| {
            const directory_file = self.root_dir.openFile(self.io, parent_path, .{ .allow_directory = true }) catch return c.SQLITE_IOERR_DIR_FSYNC;
            defer directory_file.close(self.io);
            directory_file.sync(self.io) catch return c.SQLITE_IOERR_DIR_FSYNC;
        } else {
            const directory_file: std.Io.File = .{
                .handle = self.root_dir.handle,
                .flags = .{ .nonblocking = false },
            };
            directory_file.sync(self.io) catch return c.SQLITE_IOERR_DIR_FSYNC;
        }
    }
    return c.SQLITE_OK;
}

fn retryWindowsIo(vfs: *Vfs, err: anyerror, retries: *u32) bool {
    if (builtin.os.tag != .windows) return false;
    if (err != error.WouldBlock and err != error.LockViolation and err != error.DeviceBusy and err != error.InputOutput and err != error.Unexpected) return false;
    const retry_count = @atomicLoad(i32, &win_av_retry_count, .acquire);
    if (retries.* >= @as(u32, @intCast(@max(retry_count, 0)))) return false;
    retries.* += 1;
    const delay = @atomicLoad(i32, &win_av_retry_delay_ms, .acquire);
    const duration_ms = @as(i64, @max(delay, 0)) * retries.*;
    vfs.io.sleep(.fromMilliseconds(duration_ms), .awake) catch return false;
    return true;
}

fn access(value: [*c]c.sqlite3_vfs, z_name: [*c]const u8, flags: c_int, result: [*c]c_int) callconv(.c) c_int {
    const self = fromValue(value);
    const path = self.relativePath(std.mem.span(z_name)) orelse return c.SQLITE_IOERR_ACCESS;
    const options: std.Io.Dir.AccessOptions = switch (flags) {
        c.SQLITE_ACCESS_READWRITE => .{ .read = true, .write = true },
        c.SQLITE_ACCESS_READ => .{ .read = true },
        else => .{},
    };
    self.root_dir.access(self.io, path, options) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => {
            result.* = 0;
            return c.SQLITE_OK;
        },
        else => return c.SQLITE_IOERR_ACCESS,
    };
    result.* = 1;
    return c.SQLITE_OK;
}

fn fullPathname(value: [*c]c.sqlite3_vfs, z_name: [*c]const u8, out_len: c_int, out: [*c]u8) callconv(.c) c_int {
    const self = fromValue(value);
    const path = std.mem.span(z_name);
    const required = 1 + self.name.len + 1 + path.len + 1;
    if (out_len < 0 or required > @as(usize, @intCast(out_len))) return c.SQLITE_CANTOPEN_FULLPATH;
    out[0] = '/';
    @memcpy(out[1 .. self.name.len + 1], self.name);
    out[self.name.len + 1] = '/';
    @memcpy(out[self.name.len + 2 .. required - 1], path);
    out[required - 1] = 0;
    return c.SQLITE_OK;
}

fn randomness(value: [*c]c.sqlite3_vfs, byte_count: c_int, out: [*c]u8) callconv(.c) c_int {
    if (byte_count <= 0 or out == null) return 0;
    const self = fromValue(value);
    const bytes = out[0..@intCast(byte_count)];
    self.io.randomSecure(bytes) catch self.io.random(bytes);
    return byte_count;
}

fn sleep(value: [*c]c.sqlite3_vfs, microseconds: c_int) callconv(.c) c_int {
    if (microseconds <= 0) return 0;
    const self = fromValue(value);
    self.io.sleep(.fromMicroseconds(microseconds), .awake) catch return 0;
    return microseconds;
}

const julian_unix_epoch_ms: i64 = 210866760000000;

fn currentTime(value: [*c]c.sqlite3_vfs, result: [*c]f64) callconv(.c) c_int {
    var milliseconds: c.sqlite3_int64 = undefined;
    const rc = currentTimeInt64(value, &milliseconds);
    if (rc == c.SQLITE_OK) result.* = @as(f64, @floatFromInt(milliseconds)) / 86400000.0;
    return rc;
}

fn currentTimeInt64(value: [*c]c.sqlite3_vfs, result: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const self = fromValue(value);
    const nanoseconds = std.Io.Clock.now(.real, self.io).nanoseconds;
    const unix_ms = @divFloor(nanoseconds, std.time.ns_per_ms);
    result.* = @intCast(unix_ms + julian_unix_epoch_ms);
    return c.SQLITE_OK;
}

fn dlOpen(value: [*c]c.sqlite3_vfs, filename: [*c]const u8) callconv(.c) ?*anyopaque {
    const self = fromValue(value);
    if (comptime builtin.os.tag == .windows) {
        const wide_name = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, std.mem.span(filename)) catch {
            self.setDlError("invalid library name");
            return null;
        };
        defer self.allocator.free(wide_name);
        return LoadLibraryW(wide_name.ptr) orelse {
            self.setDlError("LoadLibraryW failed");
            return null;
        };
    }
    const library = self.allocator.create(std.DynLib) catch {
        self.setDlError("out of memory");
        return null;
    };
    library.* = std.DynLib.openZ(@ptrCast(filename)) catch |err| {
        self.allocator.destroy(library);
        self.setDlError(@errorName(err));
        return null;
    };
    self.lockDlError();
    self.dl_error_len = 0;
    self.unlockDlError();
    return library;
}

fn dlError(value: [*c]c.sqlite3_vfs, out_len: c_int, out: [*c]u8) callconv(.c) void {
    const self = fromValue(value);
    if (out_len <= 0 or out == null) return;
    self.lockDlError();
    defer self.unlockDlError();
    const len = @min(self.dl_error_len, @as(usize, @intCast(out_len - 1)));
    @memcpy(out[0..len], self.dl_error[0..len]);
    out[len] = 0;
}

fn dlSym(value: [*c]c.sqlite3_vfs, handle: ?*anyopaque, symbol: [*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    _ = value;
    if (comptime builtin.os.tag == .windows) {
        const address = GetProcAddress(handle, @ptrCast(symbol)) orelse return null;
        return @ptrCast(@alignCast(address));
    }
    const library: *std.DynLib = @ptrCast(@alignCast(handle orelse return null));
    return library.lookup(*const fn () callconv(.c) void, std.mem.span(symbol));
}

fn dlClose(value: [*c]c.sqlite3_vfs, handle: ?*anyopaque) callconv(.c) void {
    const self = fromValue(value);
    if (comptime builtin.os.tag == .windows) {
        _ = FreeLibrary(handle);
        return;
    }
    const library: *std.DynLib = @ptrCast(@alignCast(handle orelse return));
    library.close();
    self.allocator.destroy(library);
}

fn setDlError(self: *Vfs, message: []const u8) void {
    self.lockDlError();
    defer self.unlockDlError();
    self.dl_error_len = @min(message.len, self.dl_error.len);
    @memcpy(self.dl_error[0..self.dl_error_len], message[0..self.dl_error_len]);
}

fn lockDlError(self: *Vfs) void {
    self.dl_error_guard.lockUncancelable(self.io);
}

fn unlockDlError(self: *Vfs) void {
    self.dl_error_guard.unlock(self.io);
}
