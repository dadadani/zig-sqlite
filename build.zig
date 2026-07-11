const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const ResolvedTarget = std.Build.ResolvedTarget;
const Query = std.Target.Query;
const builtin = @import("builtin");

const Translator = @import("translate_c").Translator;

fn addLibCHeaders(b: *std.Build, mod: *std.Build.Module, target: std.Target) void {
    const base = std.Build.LazyPath.zig_lib.path(b, "libc/include");
    if (target.os.tag.isDarwin()) {
        mod.addSystemIncludePath(base.path(b, "any-darwin-any"));
        return;
    }
    if (target.os.tag == .windows) {
        mod.addSystemIncludePath(base.path(b, "any-windows-any"));
        return;
    }

    const generic = if (target.isMuslLibC()) "generic-musl" else "generic-glibc";
    const arch = if (target.isMuslLibC())
        std.zig.target.muslArchNameHeaders(target.cpu.arch)
    else
        std.zig.target.glibcArchNameHeaders(target.cpu.arch);
    const abi = if (target.isMuslLibC()) std.zig.target.muslAbiNameHeaders(target.abi) else @tagName(target.abi);
    mod.addSystemIncludePath(base.path(b, b.fmt("{s}-{s}-{s}", .{ arch, @tagName(target.os.tag), abi })));
    mod.addSystemIncludePath(base.path(b, generic));
    mod.addSystemIncludePath(base.path(b, b.fmt("{s}-{s}-any", .{ std.zig.target.osArchName(&target), @tagName(target.os.tag) })));
    mod.addSystemIncludePath(base.path(b, b.fmt("any-{s}-any", .{@tagName(target.os.tag)})));
}

fn getTarget(original_target: ResolvedTarget) ResolvedTarget {
    return original_target;
}

const TestTarget = struct {
    query: Query,
    single_threaded: bool = false,
};

const ci_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl } },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu } },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        else => [_]TestTarget{},
    },
    else => [_]TestTarget{},
};

const all_test_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{} },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .riscv64, .abi = .musl } },
            // Disabled because it fails for some unknown reason
            // TestTarget{ .query = .{ .cpu_arch = .mips, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .os_tag = .windows } },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu } },
        },
        .freebsd => [_]TestTarget{
            TestTarget{ .query = .{} },
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
    },
    .aarch64 => switch (builtin.target.os.tag) {
        .linux, .windows, .freebsd, .macos => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
    },
    else => [_]TestTarget{
        TestTarget{ .query = .{} },
    },
};

fn computeTestTargets(isNative: bool, ci: ?bool) ?[]const TestTarget {
    if (ci != null and ci.?) return &ci_targets;

    if (isNative) {
        // If the target is native we assume the user didn't change it with -Dtarget and run all test targets.
        return &all_test_targets;
    }

    // Otherwise we run a single test target.
    return null;
}

// This creates a SQLite static library from the SQLite dependency code.
fn makeSQLiteLib(b: *std.Build, suffix_name: []const u8, dep: *std.Build.Dependency, c_flags: []const []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, link_libc: bool, sqlite_c: enum { with, without }) *std.Build.Step.Compile {
    const name = switch (sqlite_c) {
        .with => "lib-sqlite-with-sqlite-c",
        .without => "lib-sqlite-without-sqlite-c",
    };

    const name_full = b.fmt("{s}-{s}", .{ name, suffix_name });

    const mod = b.addModule(name_full, .{ .target = target, .optimize = optimize, .link_libc = link_libc });
    const lib = b.addLibrary(.{
        .name = "sqlite",
        .linkage = .static,
        .root_module = mod,
    });
    lib.root_module.addIncludePath(dep.path("./"));
    lib.root_module.addIncludePath(b.path("c"));
    addLibCHeaders(b, lib.root_module, target.result);
    if (sqlite_c == .with) {
        lib.root_module.addCSourceFile(.{
            .file = dep.path("./sqlite3.c"),
            .flags = c_flags,
        });
    }
    lib.root_module.addCSourceFile(.{
        .file = b.path("c/workaround.c"),
        .flags = c_flags,
    });

    return lib;
}

pub fn build(b: *std.Build) !void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const ci = b.option(bool, "ci", "Build and test in the CI on GitHub");
    const load_extension = b.option(bool, "load_extension", "Enable loadable extensions (default false)") orelse false;
    const localtime = b.option(bool, "localtime", "Enable SQLite local-time conversion (default false)") orelse false;
    const link_libc = load_extension or localtime;

    const query = b.standardTargetOptionsQueryOnly(.{});
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    // Upstream dependency
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    // Define C flags to use

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.append(b.allocator, "-DSQLITE_OMIT_DESERIALIZE");
    if (!localtime) try flags.append(b.allocator, "-DSQLITE_OMIT_LOCALTIME");
    try flags.append(b.allocator, "-DSQLITE_ZERO_MALLOC");
    if (!load_extension) try flags.append(b.allocator, "-DSQLITE_OMIT_LOAD_EXTENSION");

    inline for (comptime std.meta.fieldNames(EnableOptions)) |field| {
        const info = std.meta.fieldInfo(EnableOptions, std.meta.stringToEnum(std.meta.FieldEnum(EnableOptions), field).?);
        const defaultValue = info.attrs.defaultValue(info.type).?;
        const opt = b.option(bool, field, std.fmt.comptimePrint("Enable {s} (default: {})", .{ field, defaultValue })) orelse info.attrs.defaultValue(info.type).?;

        if (opt) {
            var buf: [field.len]u8 = undefined;
            const name = std.ascii.upperString(&buf, field);
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_ENABLE_{s}", .{name});

            try flags.append(b.allocator, flag);
        }
    }
    try flags.append(b.allocator, "-DSQLITE_OS_OTHER");

    const c_flags = flags.items;

    //
    // Main library and module
    //

    const translate_c = b.dependency("translate_c", .{});
    const generated_headers = addPreprocessStep(b, sqlite_dep);

    const translator_sqlite: Translator = .init(translate_c, .{
        .c_source_file = sqlite_dep.path("./sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });

    const translator_workaround: Translator = .init(translate_c, .{
        .c_source_file = b.path("c/workaround.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });

    const translator_ext: Translator = .init(translate_c, .{
        .c_source_file = generated_headers.sqlite3ext_h,
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    translator_ext.addIncludePath(generated_headers.dir);

    const sqlite_lib, const sqlite_mod = blk: {
        const lib = makeSQLiteLib(b, "lib", sqlite_dep, c_flags, target, optimize, link_libc, .with);

        const mod = b.addModule("sqlite", .{ .root_source_file = b.path("sqlite.zig"), .link_libc = link_libc, .imports = &.{
            .{
                .name = "libsqlite",
                .module = translator_sqlite.mod,
            },
            .{
                .name = "libsqlite-workaround",
                .module = translator_workaround.mod,
            },
            .{
                .name = "libsqlite-ext",
                .module = translator_ext.mod,
            },
        } });
        mod.addIncludePath(b.path("c"));
        mod.addIncludePath(sqlite_dep.path("./"));
        mod.linkLibrary(lib);

        break :blk .{ lib, mod };
    };
    b.installArtifact(sqlite_lib);

    const sqliteext_mod = blk: {
        const lib = makeSQLiteLib(b, "lib", sqlite_dep, c_flags, target, optimize, link_libc, .without);

        const mod = b.addModule("sqliteext", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = link_libc,
            .imports = &.{
                .{
                    .name = "libsqlite",
                    .module = translator_sqlite.mod,
                },
                .{
                    .name = "libsqlite-workaround",
                    .module = translator_workaround.mod,
                },
                .{
                    .name = "libsqlite-ext",
                    .module = translator_ext.mod,
                },
            },
        });
        mod.addIncludePath(b.path("c"));
        mod.linkLibrary(lib);

        break :blk mod;
    };

    //
    // Tests
    //

    const test_targets = computeTestTargets(query.isNative(), ci) orelse &[_]TestTarget{.{
        .query = query,
    }};
    const test_step = b.step("test", "Run library tests");

    // By default the tests will only be execute for native test targets, however they will be compiled
    // for _all_ targets defined in `test_targets`.
    //
    // If you want to execute tests for other targets you can pass -fqemu, -fdarling, -fwine, -frosetta.

    for (test_targets, 0..) |test_target, i| {
        const cross_target = getTarget(b.resolveTargetQuery(test_target.query));
        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        const test_name = b.fmt("{s}-{s}-{s}", .{
            try cross_target.result.zigTriple(b.allocator),
            @tagName(optimize),
            single_threaded_txt,
        });

        const name = b.fmt("testing{d}", .{i});

        const test_sqlite_lib = makeSQLiteLib(b, name, sqlite_dep, c_flags, cross_target, optimize, link_libc, .with);

        const test_translator_sqlite: Translator = .init(translate_c, .{
            .c_source_file = sqlite_dep.path("./sqlite3.h"),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = link_libc,
        });

        const test_translator_workaround: Translator = .init(translate_c, .{
            .c_source_file = b.path("c/workaround.h"),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = link_libc,
        });

        const test_translator_ext: Translator = .init(translate_c, .{
            .c_source_file = generated_headers.sqlite3ext_h,
            .target = cross_target,
            .optimize = optimize,
            .link_libc = link_libc,
        });
        test_translator_ext.addIncludePath(generated_headers.dir);

        const mod = b.addModule(test_name, .{
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = b.path("sqlite.zig"),
            .single_threaded = test_target.single_threaded,
            .link_libc = link_libc,
            .imports = &.{
                .{
                    .name = "libsqlite",
                    .module = test_translator_sqlite.mod,
                },
                .{
                    .name = "libsqlite-workaround",
                    .module = test_translator_workaround.mod,
                },
                .{
                    .name = "libsqlite-ext",
                    .module = test_translator_ext.mod,
                },
            },
        });

        const tests = b.addTest(.{
            .name = test_name,
            .root_module = mod,
        });
        tests.root_module.addIncludePath(b.path("c"));
        tests.root_module.addIncludePath(sqlite_dep.path("./"));
        tests.root_module.linkLibrary(test_sqlite_lib);

        const tests_options = b.addOptions();
        tests.root_module.addImport("build_options", tests_options.createModule());

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    // Build and execute the loadable extension test only for the selected target. Cross-target
    // library tests above still provide compile coverage for all configured test targets.
    if (query.isNative() and load_extension) {
        const zigcrypto = addZigcrypto(b, sqliteext_mod, target, optimize);
        const zigcrypto_test_run = addZigcryptoTestRun(b, sqlite_mod, target, optimize, zigcrypto);
        test_step.dependOn(&zigcrypto_test_run.step);
    }
}

const GeneratedHeaders = struct {
    sqlite3_h: std.Build.LazyPath,
    sqlite3ext_h: std.Build.LazyPath,
    dir: std.Build.LazyPath,
};

fn addPreprocessStep(b: *std.Build, sqlite_dep: *std.Build.Dependency) GeneratedHeaders {
    const preprocessor_mod = b.createModule(.{
        .root_source_file = b.path("build/Preprocessor.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const preprocessor = b.addExecutable(.{
        .name = "preprocess-headers",
        .root_module = preprocessor_mod,
    });
    const preprocess = b.addRunArtifact(preprocessor);

    preprocess.addArg("sqlite3");
    preprocess.addFileArg(sqlite_dep.path("./sqlite3.h"));
    const sqlite3_h = preprocess.addOutputFileArg("loadable-ext-sqlite3.h");

    preprocess.addArg("sqlite3ext");
    preprocess.addFileArg(sqlite_dep.path("./sqlite3ext.h"));
    const sqlite3ext_h = preprocess.addOutputFileArg("loadable-ext-sqlite3ext.h");

    const preprocess_headers = b.step("preprocess-headers", "Generate the loadable extension headers");
    preprocess_headers.dependOn(&preprocess.step);

    return .{
        .sqlite3_h = sqlite3_h,
        .sqlite3ext_h = sqlite3ext_h,
        .dir = sqlite3ext_h.dirname(),
    };
}

fn addZigcrypto(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const mod = b.addModule("zigcryto", .{
        .root_source_file = b.path("examples/zigcrypto.zig"),
        .target = getTarget(target),
        .optimize = optimize,
    });
    const exe = b.addLibrary(.{
        .name = "zigcrypto",
        .root_module = mod,
        .version = null,
        .linkage = .dynamic,
    });
    exe.root_module.addImport("sqlite", sqlite_mod);

    return exe;
}

fn addZigcryptoTestRun(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, extension: *std.Build.Step.Compile) *std.Build.Step.Run {
    const mod = b.addModule("zigcryto-test", .{
        .root_source_file = b.path("examples/zigcrypto_test.zig"),
        .target = getTarget(target),
        .optimize = optimize,
    });
    const zigcrypto_test = b.addExecutable(.{
        .name = "zigcrypto-test",
        .root_module = mod,
    });
    zigcrypto_test.root_module.addImport("sqlite", sqlite_mod);

    const run = b.addRunArtifact(zigcrypto_test);
    run.addFileArg(extension.getEmittedBin());

    return run;
}

// See https://www.sqlite.org/compile.html for flags
const EnableOptions = struct {
    // https://www.sqlite.org/fts5.html
    fts5: bool = false,
};
