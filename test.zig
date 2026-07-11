const std = @import("std");
const build_options = @import("build_options");
const mem = std.mem;
const testing = std.testing;

const Db = @import("sqlite.zig").Db;

pub fn getTestDb() !Db {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const mode = dbMode(fba.allocator());

    return try Db.init(testing.io, testing.allocator, .{
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .mode = mode,
    });
}

fn tmpDbPath(allocator: mem.Allocator) ![:0]const u8 {
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.dir.close(testing.io);
    defer tmp_dir.parent_dir.close(testing.io);

    var path_buf: [2048]u8 = undefined;

    const path_len = try std.Io.Dir.realPath(tmp_dir.dir, testing.io, &path_buf);

    const tmp_path = path_buf[0..path_len];

    const path = try std.fs.path.joinZ(allocator, &[_][]const u8{
        tmp_path,
        "zig-sqlite.db",
    });

    return path;
}

fn dbMode(allocator: mem.Allocator) Db.Mode {
    return if (build_options.in_memory) blk: {
        break :blk .{ .Memory = {} };
    } else blk: {
        if (build_options.dbfile) |dbfile| {
            return .{ .File = .{ .sub_path = allocator.dupeSentinel(u8, dbfile, 0) catch unreachable } };
        }

        const path = tmpDbPath(allocator) catch unreachable;

        std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
        break :blk .{ .File = .{ .sub_path = path } };
    };
}
