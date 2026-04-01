const std = @import("std");

pub const Type = enum {
    .int,
    .float,
    .string,

    fn fromTypeInfo(info: std.builtin.Type) Type {
        switch (info) {
            .int => |int| {
                if (int.bits == 64 and int.signedness == .signed)
                    return .int;
                @panic("Unsupported integer type");
            },

            .float => |float| {
                if (float.bits == 64)
                    return .float;

                @panic("Unsupported float type");
            },

            .pointer => |pointer| {
                const child = @typeInfo(pointer.child);
                const child_valid = switch (child) {
                    .int => |int| int.bits == 8 and int.signedness == .unsigned,
                    else => false,
                };

                const pointer_valid = pointer.size == .slice
                    and pointer.is_const
                    and !pointer.is_volatile
                    and pointer.alignment == @alignOf(u8)
                    and !pointer.is_allowzero
                    and pointer.sentinel_ptr == null;


                if (pointer_valid and child_valid)
                    return .string;

                @panic("Unsigned string type");
            },

            else => @panic("Unsigned type"),
        }
    }
};

const Value = struct {
    type: Type,
    ptr: *anyopaque,

    fn write(self: Value, arg: []const u8) !void {
        switch (self.type) {
            .int => {
                const typed_ptr: *usize = ptr;
                typed_ptr.* = try std.fmt.parseInt(usize, arg, 10);
            },

            .float => {
                const typed_ptr: *f64 = ptr;
                typed_ptr.* = try std.fmt.parseFloat(f64, arg);
            },

            .string => {
                const typed_ptr: *[]const u8 = ptr;
                typed_ptr.* = arg;
            },
        }
    }
};

const Args = struct {
    const Positional = struct {
        value: Value,
    };

    const Flag = struct {
        value: Value,
        opt: FlagOptions,
        flag: u8,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    positional: std.ArrayList(Positional),
    flags: std.ArrayList(Flag),

    pub fn init(allocator: std.mem.Allocator) Args {
        return .{
            .allocator = allocator,
            .arena = .init(allocator),
            .positional = .empty,
            .flags = .empty,
        };
    }

    pub fn deinit(self: Args) void {
        self.positional.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn positionalArg(self: *Args, T: type) !*T {
        const ptr = try self.arena.allocator().create(T);
        try self.positional.append(self.allocator, .{
            .value = .{
                .type = Type.fromTypeInfo(@typeInfo(T)),
                .ptr = ptr,
            },
        });
        return ptr;
    }

    pub fn flag(self: *Args, T: type, default: ?T, f: u8) !*?T {
        const ptr = try self.arena.allocator().create(T);
        ptr.* = default;
        try self.flags.append(self.allocator, .{
            .value = .{
                .type = Type.fromTypeInfo(@typeInfo(T)),
                .ptr = ptr,
            },
            .flag = f,
        });
        return ptr;
    }

    pub fn parse(self: *Args, args: *std.process.ArgIterator) !void {
        var i: usize = 0;

        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) {
                if (arg.len != 2)
                    return error.ArgumentParseError;

                const needle = arg[1];
                for (self.flags.items) |f| {
                    if (f.flag == needle) {
                        try f.value.write(args.next() orelse return error.ArgumentParseError);
                        break;
                    }
                }
            }
            else {
                if (i >= self.positional.len)
                    return error.ArgumentParseError;

                try self.positional.items[i].value.write(arg);
                i += 1;
            }
        }

        if (i < self.positional.len)
            return error.ArgumentParseError;
    }
};
