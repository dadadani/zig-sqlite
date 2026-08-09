const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

const c = @import("c.zig").c;
const versionGreaterThanOrEqualTo = @import("c.zig").versionGreaterThanOrEqualTo;
const getTestDb = @import("test.zig").getTestDb;
const Diagnostics = @import("sqlite.zig").Diagnostics;
const Blob = @import("sqlite.zig").Blob;
const Text = @import("sqlite.zig").Text;
const helpers = @import("helpers.zig");

const logger = std.log.scoped(.vtab);

fn hasDecls(comptime T: type, comptime names: anytype) bool {
    inline for (names) |name| {
        if (!@hasDecl(T, name)) {
            return false;
        }
    }
    return true;
}

/// ModuleContext contains state that is needed by all implementations of virtual tables.
///
/// Currently there's only an allocator.
pub const ModuleContext = struct {
    allocator: mem.Allocator,
};

fn dupeToSQLiteString(s: []const u8) ?[*c]u8 {
    const raw_buffer = c.sqlite3_malloc(@intCast(s.len + 1)) orelse return null;
    const buffer: [*c]u8 = @ptrCast(raw_buffer);

    mem.copyForwards(u8, buffer[0..s.len], s);
    buffer[s.len] = 0;

    return buffer;
}

fn setVTabError(vtab: *c.sqlite3_vtab, message: []const u8) void {
    vtab.zErrMsg = dupeToSQLiteString(message) orelse null;
}

/// VTabDiagnostics is used by the user to report error diagnostics to the virtual table.
pub const VTabDiagnostics = struct {
    const Self = @This();

    allocator: mem.Allocator,

    error_message: []const u8 = "unknown error",
    result: enum {
        error_code,
        constraint,
    } = .error_code,

    pub fn setErrorMessage(self: *Self, comptime format_string: []const u8, values: anytype) void {
        self.error_message = fmt.allocPrintSentinel(self.allocator, format_string, values, 0) catch |err| switch (err) {
            error.OutOfMemory => "can't set diagnostic message, out of memory",
        };
    }

    /// Marks this failure as a constraint violation for SQLite conflict handling.
    pub fn setConstraintErrorMessage(self: *Self, comptime format_string: []const u8, values: anytype) void {
        self.result = .constraint;
        self.setErrorMessage(format_string, values);
    }
};

pub const BestIndexBuilder = struct {
    const Self = @This();

    /// Constraint operator codes.
    /// See https://sqlite.org/c3ref/c_index_constraint_eq.html
    pub const ConstraintOp = if (versionGreaterThanOrEqualTo(3, 38, 0))
        enum {
            eq,
            gt,
            le,
            lt,
            ge,
            match,
            like,
            glob,
            regexp,
            ne,
            is_not,
            is_not_null,
            is_null,
            is,
            limit,
            offset,
            custom,
        }
    else
        enum {
            eq,
            gt,
            le,
            lt,
            ge,
            match,
            like,
            glob,
            regexp,
            ne,
            is_not,
            is_not_null,
            is_null,
            is,
            custom,
        };

    const ConstraintOpFromCodeError = error{
        InvalidCode,
    };

    fn constraintOpFromCode(code: u8) ConstraintOpFromCodeError!ConstraintOp {
        if (comptime versionGreaterThanOrEqualTo(3, 38, 0)) {
            switch (code) {
                c.SQLITE_INDEX_CONSTRAINT_LIMIT => return .limit,
                c.SQLITE_INDEX_CONSTRAINT_OFFSET => return .offset,
                else => {},
            }
        }

        switch (code) {
            c.SQLITE_INDEX_CONSTRAINT_EQ => return .eq,
            c.SQLITE_INDEX_CONSTRAINT_GT => return .gt,
            c.SQLITE_INDEX_CONSTRAINT_LE => return .le,
            c.SQLITE_INDEX_CONSTRAINT_LT => return .lt,
            c.SQLITE_INDEX_CONSTRAINT_GE => return .ge,
            c.SQLITE_INDEX_CONSTRAINT_MATCH => return .match,
            c.SQLITE_INDEX_CONSTRAINT_LIKE => return .like,
            c.SQLITE_INDEX_CONSTRAINT_GLOB => return .glob,
            c.SQLITE_INDEX_CONSTRAINT_REGEXP => return .regexp,
            c.SQLITE_INDEX_CONSTRAINT_NE => return .ne,
            c.SQLITE_INDEX_CONSTRAINT_ISNOT => return .is_not,
            c.SQLITE_INDEX_CONSTRAINT_ISNOTNULL => return .is_not_null,
            c.SQLITE_INDEX_CONSTRAINT_ISNULL => return .is_null,
            c.SQLITE_INDEX_CONSTRAINT_IS => return .is,
            else => return .custom,
        }
    }

    // WHERE clause constraint
    pub const Constraint = struct {
        // Column constrained. -1 for ROWID
        column: isize,
        op: ConstraintOp,
        /// Original SQLite operator code, including application-defined operators.
        op_code: u8,
        usable: bool,

        usage: struct {
            // If >0, constraint is part of argv to xFilter
            argv_index: i32 = 0,
            // Id >0, do not code a test for this constraint
            omit: bool = false,
        },
    };

    // ORDER BY clause
    pub const OrderBy = struct {
        /// Column number, or -1 for rowid.
        column: isize,
        order: enum {
            desc,
            asc,
        },
    };

    /// Internal state
    allocator: mem.Allocator,
    index_info: *c.sqlite3_index_info,

    /// List of WHERE clause constraints
    ///
    /// Similar to `aConstraint` in the Inputs section of sqlite3_index_info except we embed the constraint usage in there too.
    /// This makes it nicer to use for the user.
    constraints: []Constraint,

    /// List of ORDER BY terms requested by the statement.
    order_by: []OrderBy,

    /// Indicate which columns of the virtual table are actually used by the statement.
    /// If the lowest bit of colUsed is set, that means that the first column is used.
    /// The second lowest bit corresponds to the second column. And so forth.
    ///
    /// Maps to the `colUsed` field.
    columns_used: u64,

    /// Index identifier.
    /// This is passed to the filtering function to identify which index to use.
    ///
    /// Maps to the `idxNum` and `idxStr` field in sqlite3_index_info.
    /// Id id.id_str is non empty the string will be copied to a SQLite-allocated buffer and `needToFreeIdxStr` will be 1.
    id: IndexIdentifier,

    /// If the virtual table will output its rows already in the order specified by the ORDER BY clause then this can be set to true.
    /// This will indicate to SQLite that it doesn't need to do a sorting pass.
    ///
    /// Maps to the `orderByConsumed` field.
    already_ordered: bool = false,

    /// Estimated number of "disk access operations" required to execute this query.
    ///
    /// Maps to the `estimatedCost` field.
    estimated_cost: ?f64 = null,

    /// Estimated number of rows returned by this query.
    ///
    /// Maps to the `estimatedRows` field.
    ///
    /// ODO(vincent): implement this
    estimated_rows: ?i64 = null,

    /// Additiounal flags for this index.
    ///
    /// Maps to the `idxFlags` field.
    flags: struct {
        unique: bool = false,
    } = .{},

    const InitError = error{} || mem.Allocator.Error || ConstraintOpFromCodeError;

    fn init(allocator: mem.Allocator, index_info: *c.sqlite3_index_info) InitError!Self {
        const res = Self{
            .allocator = allocator,
            .index_info = index_info,
            .constraints = try allocator.alloc(Constraint, @intCast(index_info.nConstraint)),
            .order_by = try allocator.alloc(OrderBy, @intCast(index_info.nOrderBy)),
            .columns_used = @intCast(index_info.colUsed),
            .id = .{},
        };

        for (res.constraints, 0..) |*constraint, i| {
            const raw_constraint = index_info.aConstraint[i];

            constraint.column = @intCast(raw_constraint.iColumn);
            constraint.op = try constraintOpFromCode(raw_constraint.op);
            constraint.op_code = raw_constraint.op;
            constraint.usable = if (raw_constraint.usable == 1) true else false;
            constraint.usage = .{};
        }

        for (res.order_by, 0..) |*order_by, i| {
            const raw_order_by = index_info.aOrderBy[i];
            order_by.* = .{
                .column = @intCast(raw_order_by.iColumn),
                .order = if (raw_order_by.desc == 0) .asc else .desc,
            };
        }

        return res;
    }

    /// Returns true if the column is used, false otherwise.
    pub fn isColumnUsed(self: *const Self, column: usize) bool {
        const bit: u6 = @intCast(@min(column, 63));
        const mask = @as(u64, 1) << bit;
        return self.columns_used & mask == mask;
    }

    /// Returns the collation SQLite will use for a constraint.
    pub fn constraintCollation(self: *const Self, constraint_index: usize) []const u8 {
        debug.assert(constraint_index < self.constraints.len);
        const value = c.sqlite3_vtab_collation(self.index_info, @intCast(constraint_index));
        return if (value == null) "BINARY" else mem.sliceTo(value, 0);
    }

    /// Returns a constant right-hand-side value when SQLite can determine one.
    pub fn constraintRhsValue(self: *const Self, constraint_index: usize) ?FilterArg {
        debug.assert(constraint_index < self.constraints.len);
        var value: ?*c.sqlite3_value = null;
        if (c.sqlite3_vtab_rhs_value(self.index_info, @intCast(constraint_index), &value) != c.SQLITE_OK) return null;
        return .{ .value = value };
    }

    pub const DistinctMode = enum(c_int) {
        none = 0,
        unordered = 1,
        ordered = 2,
        unique = 3,
    };

    /// Describes how SQLite intends to process DISTINCT or GROUP BY.
    pub fn distinctMode(self: *const Self) DistinctMode {
        return @fromBackingInt(@intCast(c.sqlite3_vtab_distinct(self.index_info)));
    }

    /// Returns whether this is an IN constraint and optionally asks SQLite to pass the full list to xFilter.
    pub fn handleInConstraint(self: *Self, constraint_index: usize, handle: bool) bool {
        debug.assert(constraint_index < self.constraints.len);
        return c.sqlite3_vtab_in(self.index_info, @intCast(constraint_index), if (handle) 1 else -1) != 0;
    }

    /// Builds the final index data.
    ///
    /// Internally it populates the sqlite3_index_info "Outputs" fields using the information set by the user.
    pub fn build(self: *Self) error{OutOfMemory}!void {
        var index_info = self.index_info;

        // Populate the constraint usage
        var constraint_usage = index_info.aConstraintUsage[0..self.constraints.len];
        for (self.constraints, 0..) |constraint, i| {
            constraint_usage[i].argvIndex = constraint.usage.argv_index;
            constraint_usage[i].omit = if (constraint.usage.omit) 1 else 0;
        }

        // Identifiers
        index_info.idxNum = @intCast(self.id.num);
        if (self.id.str.len > 0) {
            // Must always be NULL-terminated so add 1
            const tmp = dupeToSQLiteString(self.id.str) orelse return error.OutOfMemory;

            index_info.idxStr = tmp;
            index_info.needToFreeIdxStr = 1;
        }

        index_info.orderByConsumed = if (self.already_ordered) 1 else 0;
        if (self.estimated_cost) |estimated_cost| {
            index_info.estimatedCost = estimated_cost;
        }
        if (self.estimated_rows) |estimated_rows| {
            index_info.estimatedRows = estimated_rows;
        }

        // Flags
        index_info.idxFlags = 0;
        if (self.flags.unique) {
            index_info.idxFlags |= c.SQLITE_INDEX_SCAN_UNIQUE;
        }
    }
};

/// Identifies an index for a virtual table.
///
/// The user-provided buildBestIndex functions sets the index identifier.
/// These fields are meaningless for SQLite so they can be whatever you want as long as
/// both buildBestIndex and filter functions agree on what they mean.
pub const IndexIdentifier = struct {
    num: i32 = 0,
    str: []const u8 = "",

    fn fromC(idx_num: c_int, idx_str: [*c]const u8) IndexIdentifier {
        return IndexIdentifier{
            .num = @intCast(idx_num),
            .str = if (idx_str != null) mem.sliceTo(idx_str, 0) else "",
        };
    }
};

pub const FilterArg = struct {
    value: ?*c.sqlite3_value,

    pub fn as(self: FilterArg, comptime Type: type) Type {
        const sqlite_value = self.value orelse {
            if (@typeInfo(Type) == .optional) return null;
            unreachable;
        };
        var result: Type = undefined;
        helpers.setTypeFromValue(Type, &result, sqlite_value);

        return result;
    }

    pub fn isNull(self: FilterArg) bool {
        return self.value == null or c.sqlite3_value_type(self.value) == c.SQLITE_NULL;
    }

    /// Returns whether SQLite omitted this unchanged column during an UPDATE.
    pub fn noChange(self: FilterArg) bool {
        return self.value != null and c.sqlite3_value_nochange(self.value) != 0;
    }

    /// Iterates values for an IN constraint accepted with `handleInConstraint`.
    pub fn inValues(self: FilterArg) InValues {
        return .{ .value = self.value };
    }
};

/// Arguments passed to a writable virtual table's `update` method.
pub const UpdateOperation = union(enum) {
    delete: struct {
        old_rowid: i64,
    },
    insert: struct {
        requested_rowid: ?i64,
        values: []const FilterArg,
    },
    update: struct {
        old_rowid: i64,
        requested_rowid: ?i64,
        values: []const FilterArg,
    },
};

pub const IntegrityMode = enum {
    full,
    quick,
};

pub const InValues = struct {
    value: ?*c.sqlite3_value,
    current: ?*c.sqlite3_value = null,
    started: bool = false,

    pub fn next(self: *InValues) ?FilterArg {
        const result = if (self.started)
            c.sqlite3_vtab_in_next(self.value, &self.current)
        else blk: {
            self.started = true;
            break :blk c.sqlite3_vtab_in_first(self.value, &self.current);
        };
        if (result != c.SQLITE_OK) return null;
        return .{ .value = self.current };
    }
};

/// Validates that a type implements everything required to be a cursor for a virtual table.
fn validateCursorType(comptime Table: type) void {
    const Cursor = Table.Cursor;

    // Validate the `init` function
    {
        if (!comptime hasDecls(Cursor, .{"InitError"})) {
            @compileError("the Cursor type must declare a InitError error set for the init function");
        }

        const error_message =
            \\the Cursor.init function must have the signature `fn init(allocator: std.mem.Allocator, parent: *Table) InitError!*Cursor`
        ;

        if (!comptime helpers.hasFn(Cursor, "init")) {
            @compileError("the Cursor type must have an init function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.init)).@"fn";

        if (info.param_types.len != 2) @compileError(error_message);
        if (info.param_types[0].? != mem.Allocator) @compileError(error_message);
        if (info.param_types[1].? != *Table) @compileError(error_message);
        if (info.return_type.? != Cursor.InitError!*Cursor) @compileError(error_message);
    }

    // Validate the `deinit` function
    {
        const error_message =
            \\the Cursor.deinit function must have the signature `fn deinit(cursor: *Cursor) void`
        ;

        if (!comptime helpers.hasFn(Cursor, "deinit")) {
            @compileError("the Cursor type must have a deinit function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.deinit)).@"fn";

        if (info.param_types.len != 1) @compileError(error_message);
        if (info.param_types[0].? != *Cursor) @compileError(error_message);
        if (info.return_type.? != void) @compileError(error_message);
    }

    // Validate the `next` function
    {
        if (!comptime hasDecls(Cursor, .{"NextError"})) {
            @compileError("the Cursor type must declare a NextError error set for the next function");
        }

        const error_message =
            \\the Cursor.next function must have the signature `fn next(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void`
        ;

        if (!comptime helpers.hasFn(Cursor, "next")) {
            @compileError("the Cursor type must have a next function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.next)).@"fn";

        if (info.param_types.len != 2) @compileError(error_message);
        if (info.param_types[0].? != *Cursor) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        if (info.return_type.? != Cursor.NextError!void) @compileError(error_message);
    }

    // Validate the `hasNext` function
    {
        if (!comptime hasDecls(Cursor, .{"HasNextError"})) {
            @compileError("the Cursor type must declare a HasNextError error set for the hasNext function");
        }

        const error_message =
            \\the Cursor.hasNext function must have the signature `fn hasNext(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool`
        ;

        if (!comptime helpers.hasFn(Cursor, "hasNext")) {
            @compileError("the Cursor type must have a hasNext function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.hasNext)).@"fn";

        if (info.param_types.len != 2) @compileError(error_message);
        if (info.param_types[0].? != *Cursor) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        if (info.return_type.? != Cursor.HasNextError!bool) @compileError(error_message);
    }

    // Validate the `filter` function
    {
        if (!comptime hasDecls(Cursor, .{"FilterError"})) {
            @compileError("the Cursor type must declare a FilterError error set for the filter function");
        }

        const error_message =
            \\the Cursor.filter function must have the signature `fn filter(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier, args: []FilterArg) FilterError!void`
        ;

        if (!comptime helpers.hasFn(Cursor, "filter")) {
            @compileError("the Cursor type must have a filter function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.filter)).@"fn";

        if (info.param_types.len != 4) @compileError(error_message);
        if (info.param_types[0].? != *Cursor) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        if (info.param_types[2].? != IndexIdentifier) @compileError(error_message);
        if (info.param_types[3].? != []FilterArg) @compileError(error_message);
        if (info.return_type.? != Cursor.FilterError!void) @compileError(error_message);
    }

    // Validate the `column` function
    {
        if (!comptime hasDecls(Cursor, .{"ColumnError"})) {
            @compileError("the Cursor type must declare a ColumnError error set for the column function");
        }
        if (!comptime hasDecls(Cursor, .{"Column"})) {
            @compileError("the Cursor type must declare a Column type for the return type of the column function");
        }

        const error_message =
            \\the Cursor.column function must have the signature `fn column(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics, column_number: i32) ColumnError!Column`
        ;

        if (!comptime helpers.hasFn(Cursor, "column")) {
            @compileError("the Cursor type must have a column function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.column)).@"fn";

        if (info.param_types.len != 3) @compileError(error_message);
        if (info.param_types[0].? != *Cursor) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        if (info.param_types[2].? != i32) @compileError(error_message);
        if (info.return_type.? != Cursor.ColumnError!Cursor.Column) @compileError(error_message);
    }

    // Validate the `rowId` function
    {
        if (!comptime hasDecls(Cursor, .{"RowIDError"})) {
            @compileError("the Cursor type must declare a RowIDError error set for the rowId function");
        }

        const error_message =
            \\the Cursor.rowId function must have the signature `fn rowId(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics) RowIDError!i64`
        ;

        if (!comptime helpers.hasFn(Cursor, "rowId")) {
            @compileError("the Cursor type must have a rowId function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.rowId)).@"fn";

        if (info.param_types.len != 2) @compileError(error_message);
        if (info.param_types[0].? != *Cursor) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        if (info.return_type.? != Cursor.RowIDError!i64) @compileError(error_message);
    }
}

/// Validates that a type implements everything required to be a virtual table.
fn validateTableType(comptime Table: type) void {
    // Validate the `init` function
    {
        if (!comptime hasDecls(Table, .{"InitError"})) {
            @compileError("the Table type must declare a InitError error set for the init function");
        }

        const error_message =
            \\the Table.init function must have the signature `fn init(allocator: std.mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, args: []const ModuleArgument) InitError!*Table`
        ;

        if (!comptime helpers.hasFn(Table, "init")) {
            @compileError("the Table type must have a init function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Table.init)).@"fn";

        if (info.param_types.len != 3) @compileError(error_message);
        if (info.param_types[0].? != mem.Allocator) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        // TODO(vincent): maybe allow a signature without the params since a table can do withoout them
        if (info.param_types[2].? != []const ModuleArgument) @compileError(error_message);
        if (info.return_type.? != Table.InitError!*Table) @compileError(error_message);
    }

    // Validate the `deinit` function
    {
        const error_message =
            \\the Table.deinit function must have the signature `fn deinit(table: *Table, allocator: std.mem.Allocator) void`
        ;

        if (!comptime helpers.hasFn(Table, "deinit")) {
            @compileError("the Table type must have a deinit function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Table.deinit)).@"fn";

        if (info.param_types.len != 2) @compileError(error_message);
        if (info.param_types[0].? != *Table) @compileError(error_message);
        if (info.param_types[1].? != mem.Allocator) @compileError(error_message);
        if (info.return_type.? != void) @compileError(error_message);
    }

    // Validate the `buildBestIndex` function
    {
        if (!comptime hasDecls(Table, .{"BuildBestIndexError"})) {
            @compileError("the Cursor type must declare a BuildBestIndexError error set for the buildBestIndex function");
        }

        const error_message =
            \\the Table.buildBestIndex function must have the signature `fn buildBestIndex(table: *Table, diags: *sqlite.vtab.VTabDiagnostics, builder: *sqlite.vtab.BestIndexBuilder) BuildBestIndexError!void`
        ;

        if (!comptime helpers.hasFn(Table, "buildBestIndex")) {
            @compileError("the Table type must have a buildBestIndex function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Table.buildBestIndex)).@"fn";

        if (info.param_types.len != 3) @compileError(error_message);
        if (info.param_types[0].? != *Table) @compileError(error_message);
        if (info.param_types[1].? != *VTabDiagnostics) @compileError(error_message);
        if (info.param_types[2].? != *BestIndexBuilder) @compileError(error_message);
        if (info.return_type.? != Table.BuildBestIndexError!void) @compileError(error_message);
    }

    if (!comptime hasDecls(Table, .{"Cursor"})) {
        @compileError("the Table type must declare a Cursor type");
    }
}

pub const ModuleArgument = union(enum) {
    kv: struct {
        key: []const u8,
        value: []const u8,
    },
    plain: []const u8,
};

const ParseModuleArgumentsError = error{} || mem.Allocator.Error;

fn parseModuleArguments(allocator: mem.Allocator, argc: c_int, argv: [*c]const [*c]const u8) ParseModuleArgumentsError![]ModuleArgument {
    const res = try allocator.alloc(ModuleArgument, @intCast(argc));
    errdefer allocator.free(res);

    for (res, 0..) |*marg, i| {
        // The documentation of sqlite says each string in argv is null-terminated
        const arg = mem.sliceTo(argv[i], 0);

        if (mem.indexOfScalar(u8, arg, '=')) |pos| {
            marg.* = ModuleArgument{
                .kv = .{
                    .key = arg[0..pos],
                    .value = arg[pos + 1 ..],
                },
            };
        } else {
            marg.* = ModuleArgument{ .plain = arg };
        }
    }

    return res;
}

pub fn VirtualTable(
    comptime table_name: [:0]const u8,
    comptime Table: type,
) type {
    // Validate the Table type

    comptime {
        validateTableType(Table);
        validateCursorType(Table);
        const has_savepoints = helpers.hasFn(Table, "savepoint") or helpers.hasFn(Table, "release") or helpers.hasFn(Table, "rollbackTo");
        if (has_savepoints and !helpers.hasFn(Table, "begin")) {
            @compileError("virtual table savepoint callbacks require a begin callback");
        }
    }

    const State = struct {
        const Self = @This();

        /// vtab must come first !
        /// The different functions receive a pointer to a vtab so we have to use @fieldParentPtr to get our state.
        vtab: c.sqlite3_vtab,
        /// The module context contains state that's the same for _all_ implementations of virtual tables.
        module_context: *ModuleContext,
        /// The table is the actual virtual table implementation.
        table: *Table,

        const InitError = error{} || mem.Allocator.Error || Table.InitError;

        fn init(module_context: *ModuleContext, table: *Table) InitError!*Self {
            const res = try module_context.allocator.create(Self);
            res.* = .{
                .vtab = mem.zeroes(c.sqlite3_vtab),
                .module_context = module_context,
                .table = table,
            };
            return res;
        }

        fn deinit(self: *Self) void {
            self.table.deinit(self.module_context.allocator);
            self.module_context.allocator.destroy(self);
        }
    };

    const CursorState = struct {
        const Self = @This();

        /// vtab_cursor must come first !
        /// The different functions receive a pointer to a vtab_cursor so we have to use @fieldParentPtr to get our state.
        vtab_cursor: c.sqlite3_vtab_cursor,
        /// The module context contains state that's the same for _all_ implementations of virtual tables.
        module_context: *ModuleContext,
        /// The table is the actual virtual table implementation.
        table: *Table,
        state: *State,
        cursor: *Table.Cursor,

        const InitError = error{} || mem.Allocator.Error || Table.Cursor.InitError;

        fn init(state: *State) InitError!*Self {
            const module_context = state.module_context;
            const table = state.table;
            const res = try module_context.allocator.create(Self);
            errdefer module_context.allocator.destroy(res);

            res.* = .{
                .vtab_cursor = mem.zeroes(c.sqlite3_vtab_cursor),
                .module_context = module_context,
                .table = table,
                .state = state,
                .cursor = try Table.Cursor.init(module_context.allocator, table),
            };

            return res;
        }

        fn deinit(self: *Self) void {
            self.cursor.deinit();
            self.module_context.allocator.destroy(self);
        }
    };

    return struct {
        const Self = @This();
        const module_version = if (helpers.hasFn(Table, "integrity"))
            4
        else if (helpers.hasFn(Table, "isShadowName"))
            3
        else if (helpers.hasFn(Table, "savepoint") or helpers.hasFn(Table, "release") or helpers.hasFn(Table, "rollbackTo"))
            2
        else
            1;

        pub const name = table_name;
        pub const module = makeModule();

        fn makeModule() c.sqlite3_module {
            var result = mem.zeroes(c.sqlite3_module);
            result.iVersion = @min(module_version, if (versionGreaterThanOrEqualTo(3, 44, 0)) 4 else if (versionGreaterThanOrEqualTo(3, 26, 0)) 3 else 2);
            result.xCreate = xCreate;
            result.xConnect = xConnect;
            result.xBestIndex = xBestIndex;
            result.xDisconnect = xDisconnect;
            result.xDestroy = xDestroy;
            result.xOpen = xOpen;
            result.xClose = xClose;
            result.xFilter = xFilter;
            result.xNext = xNext;
            result.xEof = xEof;
            result.xColumn = xColumn;
            result.xRowid = xRowid;
            result.xUpdate = if (helpers.hasFn(Table, "update")) xUpdate else null;
            result.xBegin = if (helpers.hasFn(Table, "begin")) xBegin else null;
            result.xSync = if (helpers.hasFn(Table, "sync")) xSync else null;
            result.xCommit = if (helpers.hasFn(Table, "commit")) xCommit else null;
            result.xRollback = if (helpers.hasFn(Table, "rollback")) xRollback else null;
            result.xRename = if (helpers.hasFn(Table, "rename")) xRename else null;
            result.xSavepoint = if (helpers.hasFn(Table, "savepoint")) xSavepoint else null;
            result.xRelease = if (helpers.hasFn(Table, "release")) xRelease else null;
            result.xRollbackTo = if (helpers.hasFn(Table, "rollbackTo")) xRollbackTo else null;
            if (@hasField(c.sqlite3_module, "xShadowName")) {
                result.xShadowName = if (helpers.hasFn(Table, "isShadowName")) xShadowName else null;
            }
            if (@hasField(c.sqlite3_module, "xIntegrity")) {
                result.xIntegrity = if (helpers.hasFn(Table, "integrity")) xIntegrity else null;
            }
            return result;
        }

        table: Table,

        fn getModuleContext(ptr: ?*anyopaque) *ModuleContext {
            return @ptrCast(@alignCast(ptr.?));
        }

        fn createState(comptime create: bool, allocator: mem.Allocator, diags: *VTabDiagnostics, module_context: *ModuleContext, args: []const ModuleArgument) !*State {
            const table = if (comptime create and helpers.hasFn(Table, "create"))
                try Table.create(allocator, diags, args)
            else if (comptime !create and helpers.hasFn(Table, "connect"))
                try Table.connect(allocator, diags, args)
            else
                try Table.init(allocator, diags, args);
            errdefer table.deinit(allocator);

            return try State.init(module_context, table);
        }

        fn xCreate(db: ?*c.sqlite3, module_context_ptr: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]u8) callconv(.c) c_int {
            return createOrConnect(true, db, module_context_ptr, argc, argv, vtab, err_str);
        }

        fn xConnect(db: ?*c.sqlite3, module_context_ptr: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]u8) callconv(.c) c_int {
            return createOrConnect(false, db, module_context_ptr, argc, argv, vtab, err_str);
        }

        fn createOrConnect(comptime create: bool, db: ?*c.sqlite3, module_context_ptr: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]u8) c_int {
            const module_context = getModuleContext(module_context_ptr);

            var arena = heap.ArenaAllocator.init(module_context.allocator);
            defer arena.deinit();

            // Convert the C-like args to more idiomatic types.
            const args = parseModuleArguments(arena.allocator(), argc, argv) catch {
                err_str.* = dupeToSQLiteString("out of memory") orelse null;
                return c.SQLITE_NOMEM;
            };

            //
            // Create the context and state, assign it to the vtab and declare the vtab.
            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const state = createState(create, module_context.allocator, &diags, module_context, args) catch {
                err_str.* = dupeToSQLiteString(diags.error_message) orelse null;
                return c.SQLITE_ERROR;
            };
            vtab.* = @ptrCast(state);

            const res = c.sqlite3_declare_vtab(db, @ptrCast(state.table.schema));
            if (res != c.SQLITE_OK) {
                vtab.* = null;
                state.deinit();
                return res;
            }

            return c.SQLITE_OK;
        }

        fn xBestIndex(vtab: [*c]c.sqlite3_vtab, index_info_ptr: [*c]c.sqlite3_index_info) callconv(.c) c_int {
            const index_info: *c.sqlite3_index_info = index_info_ptr orelse unreachable;

            //

            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));

            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();

            // Create an index builder and let the user build the index.

            var builder = BestIndexBuilder.init(arena.allocator(), index_info) catch |err| {
                logger.err("unable to create best index builder, err: {}", .{err});
                setVTabError(&state.vtab, "unable to inspect query constraints");
                return c.SQLITE_ERROR;
            };

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            state.table.buildBestIndex(&diags, &builder) catch |err| {
                logger.err("unable to build best index, err: {}", .{err});
                setVTabError(&state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };
            builder.build() catch {
                setVTabError(&state.vtab, "out of memory while building query plan");
                return c.SQLITE_NOMEM;
            };

            return c.SQLITE_OK;
        }

        fn xDisconnect(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));

            if (comptime helpers.hasFn(Table, "disconnect")) state.table.disconnect();
            state.deinit();

            return c.SQLITE_OK;
        }

        fn xDestroy(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));
            if (comptime helpers.hasFn(Table, "destroy")) state.table.destroy();
            state.deinit();
            return c.SQLITE_OK;
        }

        fn xOpen(vtab: [*c]c.sqlite3_vtab, vtab_cursor: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));

            const cursor_state = CursorState.init(state) catch |err| {
                logger.err("unable to create cursor state, err: {}", .{err});
                setVTabError(&state.vtab, "unable to create virtual table cursor");
                return c.SQLITE_ERROR;
            };
            vtab_cursor.* = @ptrCast(cursor_state);

            return c.SQLITE_OK;
        }

        fn xClose(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const cursor_ptr: *c.sqlite3_vtab_cursor = @ptrCast(vtab_cursor);
            const cursor_state: *CursorState = @fieldParentPtr("vtab_cursor", cursor_ptr);

            cursor_state.deinit();

            return c.SQLITE_OK;
        }

        fn xEof(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const cursor_ptr: *c.sqlite3_vtab_cursor = @ptrCast(vtab_cursor);
            const cursor_state: *CursorState = @fieldParentPtr("vtab_cursor", cursor_ptr);
            const cursor = cursor_state.cursor;
            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const has_next = cursor.hasNext(&diags) catch {
                logger.err("unable to call Table.Cursor.hasNext: {s}", .{diags.error_message});
                // xEof has no error return, so retain the diagnostic and stop iteration.
                setVTabError(&cursor_state.state.vtab, diags.error_message);
                return 1;
            };

            if (has_next) {
                return 0;
            } else {
                return 1;
            }
        }

        const FilterArgsFromCPointerError = error{} || mem.Allocator.Error;

        fn filterArgsFromCPointer(allocator: mem.Allocator, argc: c_int, argv: [*c]?*c.sqlite3_value) FilterArgsFromCPointerError![]FilterArg {
            const size: usize = @intCast(argc);

            const res = try allocator.alloc(FilterArg, size);
            for (res, 0..) |*item, i| {
                item.* = .{
                    .value = argv[i],
                };
            }

            return res;
        }

        fn xFilter(vtab_cursor: [*c]c.sqlite3_vtab_cursor, idx_num: c_int, idx_str: [*c]const u8, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) c_int {
            const cursor_ptr: *c.sqlite3_vtab_cursor = @ptrCast(vtab_cursor);
            const cursor_state: *CursorState = @fieldParentPtr("vtab_cursor", cursor_ptr);

            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            const id = IndexIdentifier.fromC(idx_num, idx_str);

            const args = filterArgsFromCPointer(arena.allocator(), argc, argv) catch |err| {
                logger.err("unable to create filter args, err: {}", .{err});
                setVTabError(&cursor_state.state.vtab, "out of memory while reading filter arguments");
                return c.SQLITE_ERROR;
            };

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            cursor.filter(&diags, id, args) catch {
                logger.err("unable to call Table.Cursor.filter: {s}", .{diags.error_message});
                setVTabError(&cursor_state.state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };

            return c.SQLITE_OK;
        }

        fn xNext(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const cursor_ptr: *c.sqlite3_vtab_cursor = @ptrCast(vtab_cursor);
            const cursor_state: *CursorState = @fieldParentPtr("vtab_cursor", cursor_ptr);

            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            cursor.next(&diags) catch {
                logger.err("unable to call Table.Cursor.next: {s}", .{diags.error_message});
                setVTabError(&cursor_state.state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };

            return c.SQLITE_OK;
        }

        fn xColumn(vtab_cursor: [*c]c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, n: c_int) callconv(.c) c_int {
            const cursor_ptr: *c.sqlite3_vtab_cursor = @ptrCast(vtab_cursor);
            const cursor_state: *CursorState = @fieldParentPtr("vtab_cursor", cursor_ptr);

            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const column = cursor.column(&diags, @intCast(n)) catch {
                logger.err("unable to call Table.Cursor.column: {s}", .{diags.error_message});
                setVTabError(&cursor_state.state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };

            // TODO(vincent): does it make sense to put this in setResult ? Functions could also return a union.
            const ColumnType = @TypeOf(column);
            switch (@typeInfo(ColumnType)) {
                .@"union" => |info| {
                    if (info.tag_type) |UnionTagType| {
                        inline for (info.field_names) |u_field_name| {

                            // This wasn't entirely obvious when I saw code like this elsewhere, it works because of type coercion.
                            // See https://ziglang.org/documentation/master/#Type-Coercion-unions-and-enums
                            const column_tag: std.meta.Tag(ColumnType) = column;
                            const this_tag: std.meta.Tag(ColumnType) = @field(UnionTagType, u_field_name);

                            if (column_tag == this_tag) {
                                const column_value = @field(column, u_field_name);

                                helpers.setResult(ctx, column_value);
                            }
                        }
                    } else {
                        @compileError("cannot use bare unions as a column");
                    }
                },
                else => helpers.setResult(ctx, column),
            }

            return c.SQLITE_OK;
        }

        fn xRowid(vtab_cursor: [*c]c.sqlite3_vtab_cursor, row_id_ptr: [*c]c.sqlite3_int64) callconv(.c) c_int {
            const cursor_ptr: *c.sqlite3_vtab_cursor = @ptrCast(vtab_cursor);
            const cursor_state: *CursorState = @fieldParentPtr("vtab_cursor", cursor_ptr);

            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const row_id = cursor.rowId(&diags) catch {
                logger.err("unable to call Table.Cursor.rowId: {s}", .{diags.error_message});
                setVTabError(&cursor_state.state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };

            row_id_ptr.* = row_id;

            return c.SQLITE_OK;
        }

        fn xUpdate(vtab: [*c]c.sqlite3_vtab, argc: c_int, argv: [*c]?*c.sqlite3_value, row_id_ptr: [*c]c.sqlite3_int64) callconv(.c) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));
            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();

            const operation: UpdateOperation = if (argc == 1)
                .{ .delete = .{ .old_rowid = (FilterArg{ .value = argv[0] }).as(i64) } }
            else blk: {
                const values = filterArgsFromCPointer(arena.allocator(), argc - 2, argv + 2) catch {
                    setVTabError(&state.vtab, "out of memory while reading update values");
                    return c.SQLITE_NOMEM;
                };
                const requested_rowid = (FilterArg{ .value = argv[1] }).as(?i64);
                if ((FilterArg{ .value = argv[0] }).isNull()) {
                    break :blk .{ .insert = .{ .requested_rowid = requested_rowid, .values = values } };
                }
                break :blk .{ .update = .{
                    .old_rowid = (FilterArg{ .value = argv[0] }).as(i64),
                    .requested_rowid = requested_rowid,
                    .values = values,
                } };
            };

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const row_id = state.table.update(&diags, operation) catch {
                setVTabError(&state.vtab, diags.error_message);
                return if (diags.result == .constraint) c.SQLITE_CONSTRAINT else c.SQLITE_ERROR;
            };
            if (row_id) |value| row_id_ptr.* = value;
            return c.SQLITE_OK;
        }

        fn xBegin(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            return callTransaction(Table.begin, vtab);
        }

        fn xSync(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            return callTransaction(Table.sync, vtab);
        }

        fn xCommit(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            return callTransaction(Table.commit, vtab);
        }

        fn xRollback(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            return callTransaction(Table.rollback, vtab);
        }

        fn callTransaction(comptime callback: anytype, vtab: [*c]c.sqlite3_vtab) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));
            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();
            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            callback(state.table, &diags) catch {
                setVTabError(&state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };
            return c.SQLITE_OK;
        }

        fn xRename(vtab: [*c]c.sqlite3_vtab, new_name: [*c]const u8) callconv(.c) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));
            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();
            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            state.table.rename(&diags, mem.sliceTo(new_name, 0)) catch {
                setVTabError(&state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };
            return c.SQLITE_OK;
        }

        fn xSavepoint(vtab: [*c]c.sqlite3_vtab, id: c_int) callconv(.c) c_int {
            return callSavepoint(Table.savepoint, vtab, id);
        }

        fn xRelease(vtab: [*c]c.sqlite3_vtab, id: c_int) callconv(.c) c_int {
            return callSavepoint(Table.release, vtab, id);
        }

        fn xRollbackTo(vtab: [*c]c.sqlite3_vtab, id: c_int) callconv(.c) c_int {
            return callSavepoint(Table.rollbackTo, vtab, id);
        }

        fn callSavepoint(comptime callback: anytype, vtab: [*c]c.sqlite3_vtab, id: c_int) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));
            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();
            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            callback(state.table, &diags, @as(usize, @intCast(id))) catch {
                setVTabError(&state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };
            return c.SQLITE_OK;
        }

        fn xShadowName(suffix: [*c]const u8) callconv(.c) c_int {
            return if (Table.isShadowName(mem.sliceTo(suffix, 0))) 1 else 0;
        }

        fn xIntegrity(vtab: [*c]c.sqlite3_vtab, schema: [*c]const u8, table_name_ptr: [*c]const u8, flags: c_int, error_message: [*c][*c]u8) callconv(.c) c_int {
            const state: *State = @fieldParentPtr("vtab", @as(*c.sqlite3_vtab, @ptrCast(vtab)));
            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();
            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const report = state.table.integrity(
                &diags,
                mem.sliceTo(schema, 0),
                mem.sliceTo(table_name_ptr, 0),
                if (flags == 0) .full else .quick,
            ) catch {
                setVTabError(&state.vtab, diags.error_message);
                return c.SQLITE_ERROR;
            };
            if (report) |message| {
                error_message.* = dupeToSQLiteString(message) orelse return c.SQLITE_NOMEM;
            }
            return c.SQLITE_OK;
        }
    };
}

const TestVirtualTable = struct {
    pub const Cursor = TestVirtualTableCursor;

    const Row = struct {
        foo: []const u8,
        bar: []const u8,
        baz: isize,
    };

    arena_state: heap.ArenaAllocator.State,

    rows: []Row,
    schema: [:0]const u8,

    pub const InitError = error{} || mem.Allocator.Error || fmt.ParseIntError;

    pub fn create(gpa: mem.Allocator, diags: *VTabDiagnostics, args: []const ModuleArgument) InitError!*TestVirtualTable {
        test_lifecycle.create += 1;
        return init(gpa, diags, args);
    }

    pub fn destroy(self: *TestVirtualTable) void {
        _ = self;
        test_lifecycle.destroy += 1;
    }

    pub const UpdateError = error{};

    pub fn update(self: *TestVirtualTable, diags: *VTabDiagnostics, operation: UpdateOperation) UpdateError!?i64 {
        _ = self;
        _ = diags;
        switch (operation) {
            .delete => test_callbacks.deletes += 1,
            .insert => |insert| {
                test_callbacks.inserts += 1;
                test_callbacks.last_value_count = insert.values.len;
                return insert.requested_rowid orelse 900;
            },
            .update => |update_args| {
                test_callbacks.updates += 1;
                test_callbacks.last_value_count = update_args.values.len;
            },
        }
        return null;
    }

    pub const TransactionError = error{};

    pub fn begin(self: *TestVirtualTable, diags: *VTabDiagnostics) TransactionError!void {
        _ = self;
        _ = diags;
        test_callbacks.begins += 1;
    }

    pub fn sync(self: *TestVirtualTable, diags: *VTabDiagnostics) TransactionError!void {
        _ = self;
        _ = diags;
        test_callbacks.syncs += 1;
    }

    pub fn commit(self: *TestVirtualTable, diags: *VTabDiagnostics) TransactionError!void {
        _ = self;
        _ = diags;
        test_callbacks.commits += 1;
    }

    pub fn rollback(self: *TestVirtualTable, diags: *VTabDiagnostics) TransactionError!void {
        _ = self;
        _ = diags;
        test_callbacks.rollbacks += 1;
    }

    pub const RenameError = error{};

    pub fn rename(self: *TestVirtualTable, diags: *VTabDiagnostics, new_name: []const u8) RenameError!void {
        _ = self;
        _ = diags;
        test_callbacks.renames += 1;
        test_callbacks.renamed_to_writable = mem.eql(u8, new_name, "writable_renamed");
    }

    pub const SavepointError = error{};

    pub fn savepoint(self: *TestVirtualTable, diags: *VTabDiagnostics, id: usize) SavepointError!void {
        _ = self;
        _ = diags;
        _ = id;
        test_callbacks.savepoints += 1;
    }

    pub fn release(self: *TestVirtualTable, diags: *VTabDiagnostics, id: usize) SavepointError!void {
        _ = self;
        _ = diags;
        _ = id;
        test_callbacks.releases += 1;
    }

    pub fn rollbackTo(self: *TestVirtualTable, diags: *VTabDiagnostics, id: usize) SavepointError!void {
        _ = self;
        _ = diags;
        _ = id;
        test_callbacks.rollback_tos += 1;
    }

    pub fn isShadowName(suffix: []const u8) bool {
        return mem.eql(u8, suffix, "content");
    }

    pub const IntegrityError = error{};

    pub fn integrity(self: *TestVirtualTable, diags: *VTabDiagnostics, schema: []const u8, table_name_value: []const u8, mode: IntegrityMode) IntegrityError!?[]const u8 {
        _ = self;
        _ = diags;
        _ = schema;
        _ = table_name_value;
        _ = mode;
        test_callbacks.integrity_checks += 1;
        return if (test_callbacks.report_corruption) "test corruption" else null;
    }

    pub fn init(gpa: mem.Allocator, diags: *VTabDiagnostics, args: []const ModuleArgument) InitError!*TestVirtualTable {
        var arena = heap.ArenaAllocator.init(gpa);
        const allocator = arena.allocator();

        var res = try allocator.create(TestVirtualTable);
        errdefer res.deinit(gpa);

        // Generate test data
        const rows = blk: {
            var n: usize = 0;
            for (args) |arg| {
                switch (arg) {
                    .plain => {},
                    .kv => |kv| {
                        if (mem.eql(u8, kv.key, "n")) {
                            n = fmt.parseInt(usize, kv.value, 10) catch |err| {
                                switch (err) {
                                    error.InvalidCharacter => diags.setErrorMessage("not a number: {s}", .{kv.value}),
                                    else => diags.setErrorMessage("got error while parsing value {s}: {}", .{ kv.value, err }),
                                }
                                return err;
                            };
                        }
                    },
                }
            }

            //

            const data = &[_][]const u8{
                "Vincent",
                "José",
                "Michel",
            };

            var rand = std.Random.DefaultPrng.init(204882485);

            const tmp = try allocator.alloc(Row, n);
            for (tmp) |*s| {
                const foo_value = data[rand.random().intRangeLessThan(usize, 0, data.len)];
                const bar_value = data[rand.random().intRangeLessThan(usize, 0, data.len)];
                const baz_value = rand.random().intRangeAtMost(isize, 0, 200);

                s.* = .{
                    .foo = foo_value,
                    .bar = bar_value,
                    .baz = baz_value,
                };
            }

            break :blk tmp;
        };
        res.rows = rows;

        // Build the schema
        res.schema = try allocator.dupeSentinel(u8,
            \\CREATE TABLE foobar(foo TEXT, bar TEXT, baz INTEGER, nullable_value INTEGER)
        , 0);

        res.arena_state = arena.state;

        return res;
    }

    pub fn deinit(self: *TestVirtualTable, gpa: mem.Allocator) void {
        self.arena_state.promote(gpa).deinit();
    }

    fn connect(self: *TestVirtualTable) anyerror!void {
        _ = self;
        debug.print("connect\n", .{});
    }

    pub const BuildBestIndexError = error{} || mem.Allocator.Error || std.Io.Writer.Error;

    pub fn buildBestIndex(self: *TestVirtualTable, diags: *VTabDiagnostics, builder: *BestIndexBuilder) BuildBestIndexError!void {
        _ = self;
        _ = diags;

        test_planner.order_by_count = builder.order_by.len;
        if (builder.order_by.len > 0) {
            test_planner.first_order_by_column = builder.order_by[0].column;
            test_planner.first_order_by_desc = builder.order_by[0].order == .desc;
        }
        test_planner.column_zero_used = builder.isColumnUsed(0);

        var id_str_writer = std.Io.Writer.Allocating.init(builder.allocator);
        errdefer id_str_writer.deinit();
        // var id_str_writer = builder.id_str_buffer.writer(builder.allocator);

        var argv_index: i32 = 0;
        for (builder.constraints) |*constraint| {
            if (constraint.op == .eq) {
                argv_index += 1;
                constraint.usage.argv_index = argv_index;

                try id_str_writer.writer.print("={d:<6}", .{constraint.column});
            }
        }

        builder.id.str = try id_str_writer.toOwnedSlice();
        builder.estimated_cost = 200;
        builder.estimated_rows = 200;
    }

    /// An iterator over the rows of this table capable of applying filters.
    /// The filters are used when the index asks for it.
    const Iterator = struct {
        rows: []Row,
        pos: usize,

        filters: struct {
            foo: ?[]const u8 = null,
            bar: ?[]const u8 = null,
        } = .{},

        fn init(rows: []Row) Iterator {
            return Iterator{
                .rows = rows,
                .pos = 0,
            };
        }

        fn currentRow(it: *Iterator) Row {
            return it.rows[it.pos];
        }

        fn hasNext(it: *Iterator) bool {
            return it.pos < it.rows.len;
        }

        fn next(it: *Iterator) void {
            it.pos += 1;
            it.seekToMatch();
        }

        fn seekToMatch(it: *Iterator) void {
            while (it.pos < it.rows.len and !it.matches(it.rows[it.pos])) : (it.pos += 1) {}
        }

        fn matches(it: *const Iterator, row: Row) bool {
            if (it.filters.foo) |foo| if (!mem.eql(u8, foo, row.foo)) return false;
            if (it.filters.bar) |bar| if (!mem.eql(u8, bar, row.bar)) return false;
            return true;
        }
    };
};

const TestVirtualTableCursor = struct {
    allocator: mem.Allocator,
    parent: *TestVirtualTable,
    iterator: TestVirtualTable.Iterator,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(allocator: mem.Allocator, parent: *TestVirtualTable) InitError!*TestVirtualTableCursor {
        const res = try allocator.create(TestVirtualTableCursor);
        res.* = .{
            .allocator = allocator,
            .parent = parent,
            .iterator = TestVirtualTable.Iterator.init(parent.rows),
        };
        return res;
    }

    pub fn deinit(cursor: *TestVirtualTableCursor) void {
        cursor.allocator.destroy(cursor);
    }

    pub const FilterError = error{InvalidColumn} || fmt.ParseIntError;

    pub fn filter(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics, index: IndexIdentifier, args: []FilterArg) FilterError!void {
        _ = diags;

        var id = index.str;

        // NOTE(vincent): this is an ugly ass parser for the index string, don't judge me.

        var i: usize = 0;
        while (true) {
            const pos = mem.indexOfScalar(u8, id, '=') orelse break;

            const arg = args[i];
            i += 1;

            // 3 chars for the '=' marker
            // 6 chars because we format all columns in a 6 char wide string
            const col_str = id[pos + 1 .. pos + 1 + 6];
            const col = try fmt.parseInt(i32, mem.trimEnd(u8, col_str, " "), 10);

            id = id[pos + 1 + 6 ..];

            //

            if (col == 0) {
                cursor.iterator.filters.foo = arg.as(?[]const u8);
            } else if (col == 1) {
                cursor.iterator.filters.bar = arg.as(?[]const u8);
            } else if (col == 2) {
                _ = arg.as(isize);
            } else {
                return error.InvalidColumn;
            }
        }

        cursor.iterator.pos = 0;
        cursor.iterator.seekToMatch();
    }

    pub const NextError = error{};

    pub fn next(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics) NextError!void {
        _ = diags;

        cursor.iterator.next();
    }

    pub const HasNextError = error{};

    pub fn hasNext(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics) HasNextError!bool {
        _ = diags;

        return cursor.iterator.hasNext();
    }

    pub const Column = union(enum) {
        foo: []const u8,
        bar: []const u8,
        baz: isize,
        nullable_value: ?i64,
    };

    pub const ColumnError = error{InvalidColumn};

    pub fn column(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics, column_number: i32) ColumnError!Column {
        _ = diags;

        const row = cursor.iterator.currentRow();

        switch (column_number) {
            0 => return Column{ .foo = row.foo },
            1 => return Column{ .bar = row.bar },
            2 => return Column{ .baz = row.baz },
            3 => return Column{ .nullable_value = null },
            else => return error.InvalidColumn,
        }
    }

    pub const RowIDError = error{};

    pub fn rowId(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics) RowIDError!i64 {
        _ = diags;

        return @intCast(cursor.iterator.pos);
    }
};

var test_lifecycle = struct {
    create: usize = 0,
    destroy: usize = 0,
}{};

var test_callbacks = struct {
    inserts: usize = 0,
    updates: usize = 0,
    deletes: usize = 0,
    last_value_count: usize = 0,
    begins: usize = 0,
    syncs: usize = 0,
    commits: usize = 0,
    rollbacks: usize = 0,
    savepoints: usize = 0,
    releases: usize = 0,
    rollback_tos: usize = 0,
    renames: usize = 0,
    renamed_to_writable: bool = false,
    integrity_checks: usize = 0,
    report_corruption: bool = false,
}{};

var test_planner = struct {
    order_by_count: usize = 0,
    first_order_by_column: isize = 0,
    first_order_by_desc: bool = false,
    column_zero_used: bool = false,
}{};

test "best index column usage follows SQLite bit positions" {
    var builder = BestIndexBuilder{
        .allocator = testing.allocator,
        .index_info = undefined,
        .constraints = &.{},
        .order_by = &.{},
        .columns_used = (@as(u64, 1) << 0) | (@as(u64, 1) << 63),
        .id = .{},
    };

    try testing.expect(builder.isColumnUsed(0));
    try testing.expect(!builder.isColumnUsed(1));
    try testing.expect(builder.isColumnUsed(63));
    try testing.expect(builder.isColumnUsed(64));
}

test "virtual table derives module version and recognizes shadow names" {
    const Module = VirtualTable("module_features", TestVirtualTable);
    try testing.expectEqual(@as(c_int, 4), Module.module.iVersion);
    try testing.expectEqual(@as(c_int, 1), Module.module.xShadowName.?("content"));
    try testing.expectEqual(@as(c_int, 0), Module.module.xShadowName.?("other"));
}

test "virtual table" {
    var db = try getTestDb();
    defer db.deinit();

    var myvtab_module_context = ModuleContext{
        .allocator = testing.allocator,
    };

    try db.createVirtualTable(
        "myvtab",
        &myvtab_module_context,
        TestVirtualTable,
    );

    var diags = Diagnostics{};
    try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS vtab_foobar USING myvtab(n=200)", .{ .diags = &diags }, .{});

    // Filter with both `foo` and `bar`

    var stmt = try db.prepareWithDiags(
        "SELECT rowid, foo, bar, baz, nullable_value FROM vtab_foobar WHERE foo = ?{[]const u8} AND bar = ?{[]const u8} AND baz > ?{usize}",
        .{ .diags = &diags },
    );
    defer stmt.deinit();

    var rows_arena = heap.ArenaAllocator.init(testing.allocator);
    defer rows_arena.deinit();

    const rows = try stmt.all(
        struct {
            id: i64,
            foo: []const u8,
            bar: []const u8,
            baz: usize,
            nullable_value: ?i64,
        },
        rows_arena.allocator(),
        .{ .diags = &diags },
        .{
            .foo = @as([]const u8, "Vincent"),
            .bar = @as([]const u8, "Michel"),
            .baz = @as(usize, 2),
        },
    );
    try testing.expect(rows.len > 0);

    for (rows) |row| {
        try testing.expectEqualStrings("Vincent", row.foo);
        try testing.expectEqualStrings("Michel", row.bar);
        try testing.expect(row.baz > 2);
        try testing.expectEqual(null, row.nullable_value);
    }
}

test "virtual table exposes planner inputs" {
    var db = try getTestDb();
    defer db.deinit();
    var module_context = ModuleContext{ .allocator = testing.allocator };
    try db.createVirtualTable("planner_vtab", &module_context, TestVirtualTable);
    try db.exec("CREATE VIRTUAL TABLE planner_test USING planner_vtab(n=1)", .{}, .{});
    test_planner = .{};

    _ = try db.one([20:0]u8, "SELECT foo FROM planner_test ORDER BY bar DESC LIMIT 1", .{}, .{});
    try testing.expectEqual(@as(usize, 1), test_planner.order_by_count);
    try testing.expectEqual(@as(isize, 1), test_planner.first_order_by_column);
    try testing.expect(test_planner.first_order_by_desc);
    try testing.expect(test_planner.column_zero_used);
}

test "virtual table dispatches create and destroy separately" {
    test_lifecycle = .{};

    var db = try getTestDb();
    defer db.deinit();
    var module_context = ModuleContext{ .allocator = testing.allocator };
    try db.createVirtualTable("lifecycle_vtab", &module_context, TestVirtualTable);

    try db.exec("CREATE VIRTUAL TABLE lifecycle_test USING lifecycle_vtab(n=0)", .{}, .{});
    try testing.expectEqual(@as(usize, 1), test_lifecycle.create);
    try testing.expectEqual(@as(usize, 0), test_lifecycle.destroy);

    try db.exec("DROP TABLE lifecycle_test", .{}, .{});
    try testing.expectEqual(@as(usize, 1), test_lifecycle.destroy);
}

test "writable virtual table callbacks" {
    var db = try getTestDb();
    defer db.deinit();
    var module_context = ModuleContext{ .allocator = testing.allocator };
    try db.createVirtualTable("writable_vtab", &module_context, TestVirtualTable);
    try db.exec("CREATE VIRTUAL TABLE writable USING writable_vtab(n=1)", .{}, .{});
    test_callbacks = .{};

    try db.exec("BEGIN", .{}, .{});
    try db.exec("INSERT INTO writable(foo, bar, baz) VALUES ('new', 'row', 1)", .{}, .{});
    try testing.expectEqual(@as(?i64, 900), try db.one(i64, "SELECT last_insert_rowid()", .{}, .{}));
    try db.exec("SAVEPOINT vtab_savepoint", .{}, .{});
    try db.exec("UPDATE writable SET foo = 'updated'", .{}, .{});
    try db.exec("ROLLBACK TO vtab_savepoint", .{}, .{});
    try db.exec("RELEASE vtab_savepoint", .{}, .{});
    try db.exec("COMMIT", .{}, .{});

    try testing.expectEqual(@as(usize, 1), test_callbacks.inserts);
    try testing.expectEqual(@as(usize, 1), test_callbacks.updates);
    try testing.expectEqual(@as(usize, 4), test_callbacks.last_value_count);
    try testing.expectEqual(@as(usize, 1), test_callbacks.begins);
    try testing.expectEqual(@as(usize, 1), test_callbacks.syncs);
    try testing.expectEqual(@as(usize, 1), test_callbacks.commits);
    try testing.expect(test_callbacks.savepoints > 0);
    try testing.expect(test_callbacks.rollback_tos > 0);
    try testing.expect(test_callbacks.releases > 0);

    try db.exec("DELETE FROM writable", .{}, .{});
    try testing.expectEqual(@as(usize, 1), test_callbacks.deletes);

    try db.exec("BEGIN", .{}, .{});
    try db.exec("INSERT INTO writable(foo, bar, baz) VALUES ('rolled', 'back', 2)", .{}, .{});
    try db.exec("ROLLBACK", .{}, .{});
    try testing.expectEqual(@as(usize, 1), test_callbacks.rollbacks);

    try db.exec("ALTER TABLE writable RENAME TO writable_renamed", .{}, .{});
    try testing.expectEqual(@as(usize, 1), test_callbacks.renames);
    try testing.expect(test_callbacks.renamed_to_writable);

    test_callbacks.report_corruption = true;
    const integrity_report = try db.one([20:0]u8, "PRAGMA integrity_check", .{}, .{});
    try testing.expectEqualStrings("test corruption", mem.sliceTo(&integrity_report.?, 0));
    try testing.expect(test_callbacks.integrity_checks > 0);
}

test "parse module arguments" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try allocator.alloc([*c]const u8, 20);
    for (args, 0..) |*arg, i| {
        const tmp = try fmt.allocPrintSentinel(allocator, "arg={d}", .{i}, 0);
        arg.* = @ptrCast(tmp);
    }

    const res = try parseModuleArguments(
        allocator,
        @intCast(args.len),
        @ptrCast(args),
    );
    try testing.expectEqual(@as(usize, 20), res.len);

    for (res, 0..) |arg, i| {
        try testing.expectEqualStrings("arg", arg.kv.key);
        try testing.expectEqual(i, try fmt.parseInt(usize, arg.kv.value, 10));
    }
}
