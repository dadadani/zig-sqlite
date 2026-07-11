const std = @import("std");

comptime {
    _ = strcmp;
    _ = strncmp;
    _ = strchr;
    _ = strrchr;
    _ = strspn;
    _ = strcspn;
    _ = memchr;
}

export fn strcmp(a: [*:0]const c_char, b: [*:0]const c_char) callconv(.c) c_int {
    return strncmp(a, b, std.math.maxInt(usize));
}

export fn strncmp(a: [*:0]const c_char, b: [*:0]const c_char, max: usize) callconv(.c) c_int {
    return switch (std.mem.boundedOrderZ(u8, @ptrCast(a), @ptrCast(b), max)) {
        .eq => 0,
        .gt => 1,
        .lt => -1,
    };
}
export fn strchr(str: [*:0]const c_char, value: c_int) callconv(.c) ?[*:0]c_char {
    const str_u8: [*:0]const u8 = @ptrCast(str);
    const len = std.mem.len(str_u8);

    if (value == 0) return @constCast(str + len);
    return @constCast(str[std.mem.findScalar(u8, str_u8[0..len], @truncate(@as(c_uint, @bitCast(value)))) orelse return null ..]);
}

export fn strrchr(str: [*:0]const c_char, value: c_int) callconv(.c) ?[*:0]c_char {
    const str_u8: [*:0]const u8 = @ptrCast(str);
    // std.mem.len(str) + 1 to not special case '\0'
    return @constCast(str[std.mem.findScalarLast(u8, str_u8[0 .. std.mem.len(str_u8) + 1], @truncate(@as(c_uint, @bitCast(value)))) orelse return null ..]);
}

export fn strspn(dst: [*:0]const c_char, values: [*:0]const c_char) callconv(.c) usize {
    const dst_slice = std.mem.span(@as([*:0]const u8, @ptrCast(dst)));
    return std.mem.findNone(u8, dst_slice, std.mem.span(@as([*:0]const u8, @ptrCast(values)))) orelse dst_slice.len;
}

export fn strcspn(dst: [*:0]const c_char, values: [*:0]const c_char) callconv(.c) usize {
    const dst_slice = std.mem.span(@as([*:0]const u8, @ptrCast(dst)));
    return std.mem.findAny(u8, dst_slice, std.mem.span(@as([*:0]const u8, @ptrCast(values)))) orelse dst_slice.len;
}

export fn memchr(ptr: *const anyopaque, value: c_int, len: usize) callconv(.c) ?*anyopaque {
    const bytes: [*]const u8 = @ptrCast(ptr);
    return @constCast(bytes[std.mem.findScalar(u8, bytes[0..len], @truncate(@as(c_uint, @bitCast(value)))) orelse return null ..]);
}
