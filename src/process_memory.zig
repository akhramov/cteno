const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const MemoryReader = @This();

base: [*]const u8 = undefined,
pid: std.c.pid_t,
reader: Reader,
seek: u64,

const vtable: Reader.VTable = .{ .stream = stream };

pub fn init(pid: std.c.pid_t, allocator: Allocator) !MemoryReader {
    const buffer = try allocator.alloc(u8, 1024);
    return .{
        .pid = pid,
        .seek = 0,
        .reader = .{
            .vtable = &vtable,
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
    };
}

pub fn digMemory(self: anytype, item: anytype, args: anytype) @TypeOf(digInner(self, @TypeOf(item), item, args, 0)) {
    return try digInner(self, @TypeOf(item), item, args, 0);
}

/// I will call myself out.
fn digInner(self: anytype, item_ty: type, item: item_ty, args: anytype, cur: anytype) if (cur == args.len)
    @TypeOf(item)
else
    @TypeOf(digInner(self, anyerror!fieldType(item_ty, args[cur]), readField(self, item_ty, item, args, cur), args, cur + 1)) {
    if (cur == args.len) {
        return item;
    }

    const next_item = try readField(self, item_ty, item, args, cur);

    return digInner(self, @TypeOf(next_item), next_item, args, cur + 1);
}

pub fn readField(self: anytype, item_ty: type, item: item_ty, args: anytype, cur: anytype) !fieldType(@TypeOf(item), args[cur]) {
    const unwrapped_item = switch (@typeInfo(item_ty)) {
        .error_union => try item,
        else => item,
    };

    switch (@typeInfo((@TypeOf(args[cur])))) {
        .type => {
            self.seekTo(@as([*]const args[cur], @ptrFromInt(unwrapped_item)));
            return try self.reader.takeStruct(args[cur], .native);
        },
        .@"struct" => {
            const field = @field(unwrapped_item, args[cur][0]);

            switch (@typeInfo((@TypeOf(field)))) {
                .pointer, .optional => {
                    const ptr: [*]const args[cur][1] = @ptrCast(field);
                    self.seekTo(ptr);

                    return try self.reader.takeStruct(args[cur][1], .native);
                },
                else => {
                    const offset = @offsetOf(@TypeOf(unwrapped_item), args[cur][0]);
                    // TODO: this is sad.
                    // assumes that we ended here immediately after reading the parent struct
                    const location = self.base + self.currentOffset() - @sizeOf(item_ty) + offset;
                    const ptr: args[cur][1] = @ptrCast(location);
                    return ptr;
                },
            }
        },
        else => {
            const field = @field(unwrapped_item, args[cur]);
            return switch (@typeInfo(@TypeOf(field))) {
                .pointer => blk: {
                    self.seekTo(field);

                    break :blk try self.reader.takeStruct(@TypeOf(field[0]), .native);
                },
                else => field,
            };
        },
    }
}

inline fn fieldType(item: anytype, field_name: anytype) type {
    switch (@typeInfo((@TypeOf(field_name)))) {
        .type => return field_name,
        .@"struct" => return field_name[1],
        else => {
            const field = @FieldType(item, field_name);

            return switch (@typeInfo(field)) {
                .pointer => @TypeOf(@as(field, null)[0]),
                else => field,
            };
        },
    }
}

pub fn rebase(self: *MemoryReader, base: [*]const u8) void {
    const zero: usize = 0;
    self.seekTo(zero);
    self.base = base;
}

pub fn seekTo(self: *MemoryReader, raw_position: anytype) void {
    const position = switch (@typeInfo(@TypeOf(raw_position))) {
        .int => raw_position,
        .pointer => blk: {
            const ptr: @TypeOf(self.base) = @ptrCast(raw_position);
            break :blk ptr - self.base;
        },
        else => comptime unreachable,
    };
    self.reader.tossBuffered();
    self.seek = position;
}

/// Returns the current logical position within the process map
pub fn currentOffset(self: *MemoryReader) u64 {
    return self.seek + self.reader.seek - self.reader.end;
}

fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) !usize {
    const self: *MemoryReader = @alignCast(@fieldParentPtr("reader", r));

    var buffer: [1024]u8 = undefined;
    const slice: []u8 = limit.slice(&buffer);

    const bytes_read = try readProcessMemory(self.pid, self.base + self.seek, slice);

    std.debug.assert(bytes_read == try w.write(slice));
    self.seek += bytes_read;

    return bytes_read;
}

fn readProcessMemory(pid: i32, ptr: [*]const u8, buffer: []u8) !usize {
    const local = [_]std.posix.iovec{.{
        .base = buffer.ptr,
        .len = buffer.len,
    }};

    const remote = [_]std.posix.iovec_const{.{
        .base = ptr,
        .len = buffer.len,
    }};

    const result = std.os.linux.process_vm_readv(pid, &local, &remote, 0);
    if (std.os.linux.errno(result) != .SUCCESS) {
        return error.ReadFailed;
    }

    return result;
}

test digMemory {
    const allocator = std.testing.allocator;
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    const MemoryReaderMock = struct {
        reader: Reader,
        base: usize = 0,

        fn init(buf: []u8) @This() {
            return .{
                .reader = Reader.fixed(buf),
            };
        }

        pub fn seekTo(self: *@This(), raw_position: anytype) void {
            const position = switch (@typeInfo(@TypeOf(raw_position))) {
                .int => raw_position,
                .pointer => blk: {
                    const ptr: @TypeOf(self.reader.buffer.ptr) = @ptrCast(@constCast(raw_position));
                    break :blk ptr - self.reader.buffer.ptr;
                },
                else => comptime unreachable,
            };
            self.reader.seek = position;
        }

        pub fn currentOffset(self: *@This()) usize {
            return self.reader.seek;
        }
    };

    var writer = Writer.fixed(buffer);

    const TestStruct = extern struct {
        foo: extern struct {
            next: ?*const usize,
            value: usize,
        },
    };

    try writer.writeStruct(TestStruct{
        .foo = .{
            .next = @ptrFromInt(@intFromPtr(&buffer[@sizeOf(TestStruct) * 2])),
            .value = 4,
        },
    }, .native);

    try writer.writeStruct(TestStruct{
        .foo = .{
            .next = null,
            .value = 8,
        },
    }, .native);

    try writer.writeStruct(TestStruct{
        .foo = .{
            .next = null,
            .value = 42,
        },
    }, .native);

    var memory_reader = MemoryReaderMock.init(buffer);

    // Read the nested struct field, cast the pointer type, follow the pointer and read the nested struct field
    const value = try digMemory(&memory_reader, @intFromPtr(buffer.ptr), .{ TestStruct, "foo", .{ "next", TestStruct }, "foo", "value" });
    try std.testing.expectEqual(value, 42);
}
