const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").raw_c;

const header_size = 16;
const allocation_alignment: std.mem.Alignment = .@"8";

const Header = struct {
    allocation_size: usize,
    requested_size: usize,
};

const default_allocator = if (builtin.single_threaded)
    if (builtin.os.tag == .linux or builtin.cpu.arch.isWasm()) std.heap.brk_allocator else std.heap.page_allocator
else
    std.heap.smp_allocator;

var allocator: std.mem.Allocator = default_allocator;
var configured = false;
var configure_lock: std.atomic.Mutex = .unlocked;

pub const ConfigureError = error{
    SQLiteAlreadyInitialized,
    SQLiteConfigFailed,
};

pub fn configure(new_allocator: std.mem.Allocator) ConfigureError!void {
    while (!configure_lock.tryLock()) {}
    defer configure_lock.unlock();

    if (@atomicLoad(bool, &configured, .acquire)) return error.SQLiteAlreadyInitialized;
    const previous = allocator;
    allocator = new_allocator;
    install() catch |err| {
        allocator = previous;
        return err;
    };
}

pub fn ensureConfigured() ConfigureError!void {
    if (@atomicLoad(bool, &configured, .acquire)) return;
    while (!configure_lock.tryLock()) {}
    defer configure_lock.unlock();
    if (@atomicLoad(bool, &configured, .acquire)) return;
    try install();
}

fn install() ConfigureError!void {
    const result = c.sqlite3_config(c.SQLITE_CONFIG_MALLOC, &methods);
    if (result == c.SQLITE_MISUSE) return error.SQLiteAlreadyInitialized;
    if (result != c.SQLITE_OK) return error.SQLiteConfigFailed;
    @atomicStore(bool, &configured, true, .release);
}

const methods: c.sqlite3_mem_methods = .{
    .xMalloc = malloc,
    .xFree = free,
    .xRealloc = realloc,
    .xSize = size,
    .xRoundup = roundup,
    .xInit = init,
    .xShutdown = shutdown,
    .pAppData = null,
};

fn malloc(byte_count: c_int) callconv(.c) ?*anyopaque {
    if (byte_count <= 0) return null;
    const requested: usize = @intCast(byte_count);
    const total = std.math.add(usize, header_size, requested) catch return null;
    const memory = allocator.alignedAlloc(u8, allocation_alignment, total) catch return null;
    const header: *Header = @ptrCast(memory.ptr);
    header.* = .{ .allocation_size = total, .requested_size = requested };
    return memory.ptr + header_size;
}

fn free(optional_pointer: ?*anyopaque) callconv(.c) void {
    const pointer = optional_pointer orelse return;
    const address = @intFromPtr(pointer) - header_size;
    const header: *Header = @ptrFromInt(address);
    const memory: []align(8) u8 = @as([*]align(8) u8, @ptrFromInt(address))[0..header.allocation_size];
    allocator.free(memory);
}

fn realloc(optional_pointer: ?*anyopaque, byte_count: c_int) callconv(.c) ?*anyopaque {
    if (optional_pointer == null) return malloc(byte_count);
    if (byte_count <= 0) {
        free(optional_pointer);
        return null;
    }
    const old_pointer = optional_pointer.?;
    const old_header: *Header = @ptrFromInt(@intFromPtr(old_pointer) - header_size);
    const new_pointer = malloc(byte_count) orelse return null;
    const old_bytes: [*]const u8 = @ptrCast(old_pointer);
    const new_bytes: [*]u8 = @ptrCast(new_pointer);
    @memcpy(new_bytes[0..@min(old_header.requested_size, @as(usize, @intCast(byte_count)))], old_bytes[0..@min(old_header.requested_size, @as(usize, @intCast(byte_count)))]);
    free(old_pointer);
    return new_pointer;
}

fn size(pointer: ?*anyopaque) callconv(.c) c_int {
    const address = @intFromPtr(pointer orelse return 0) - header_size;
    const header: *const Header = @ptrFromInt(address);
    return @intCast(header.requested_size);
}

fn roundup(byte_count: c_int) callconv(.c) c_int {
    if (byte_count <= 0) return 0;
    const value: u32 = @intCast(byte_count);
    const rounded = std.mem.alignForward(u32, value, 8);
    if (rounded > std.math.maxInt(c_int)) return 0;
    return @intCast(rounded);
}

fn init(_: ?*anyopaque) callconv(.c) c_int {
    return c.SQLITE_OK;
}

fn shutdown(_: ?*anyopaque) callconv(.c) void {}

test "SQLite allocator methods" {
    const testing = std.testing;
    const pointer = malloc(13) orelse return error.OutOfMemory;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(pointer) % 8);
    try testing.expectEqual(@as(c_int, 13), size(pointer));

    const bytes: [*]u8 = @ptrCast(pointer);
    @memset(bytes[0..13], 0xa5);
    const resized = realloc(pointer, 29) orelse return error.OutOfMemory;
    defer free(resized);
    try testing.expectEqual(@as(c_int, 29), size(resized));
    var expected: [13]u8 = undefined;
    @memset(&expected, 0xa5);
    try testing.expectEqualSlices(u8, &expected, @as([*]u8, @ptrCast(resized))[0..13]);
    try testing.expectEqual(@as(c_int, 16), roundup(13));
}
