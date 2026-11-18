/// Aggregates the traces for the folded flamegraph representation
const std = @import("std");

const Allocator = std.mem.Allocator;
const Self = @This();
const Writer = std.Io.Writer;

traces: std.StringHashMap(usize), // TODO: use radix tree for more compact representation.
allocator: Allocator,
accumulator: ?[]u8,

/// Initialises the aggregator
pub fn init(allocator: Allocator) Self {
    return .{
        .traces = .init(allocator),
        .allocator = allocator,
        .accumulator = null,
    };
}

fn pushFrame(self: *Self, frame: anytype) !void {
    const new = try self.allocator.print("{s};{s} ({s}:{d})", .{ self.accumulator orelse "", frame.name, frame.filename, frame.line });

    if (self.accumulator) |acc| {
        self.allocator.free(acc);
    }

    self.accumulator = new;
}

/// Tag holds the traces root
fn finalizeTrace(self: *Self, thread: i32) !void {
    const key = try self.allocator.print("thread {d}{s}", .{ thread, self.accumulator.? });
    const entry = try self.traces.getOrPut(key);
    if (!entry.found_existing) {
        entry.value_ptr.* = 1;
    } else {
        self.allocator.free(key);
        entry.value_ptr.* = entry.value_ptr.* + 1;
    }

    if (self.accumulator) |acc| {
        self.allocator.free(acc);
    }
    self.accumulator = null;
}

fn deinit(self: *Self) void {
    if (self.accumulator) |acc| {
        self.allocator.free(acc);
    }

    var keyIter = self.traces.keyIterator();
    while (keyIter.next()) |key| {
        self.allocator.free(key.*);
    }

    self.traces.deinit();
}

pub fn dump(self: Self, writer: *Writer) !void {
    var iter = self.traces.iterator();

    while (iter.next()) |item| {
        const val = item.value_ptr.*;
        const key = item.key_ptr.*;

        try writer.print("{s} {}\n", .{ key, val });
    }
}

test init {
    const allocator = std.testing.allocator;
    var aggregator = init(allocator);
    defer aggregator.deinit();

    for (0..4) |_| {
        try aggregator.pushFrame(.{ .name = "function_name", .filename = "/path/to/filename", .line = 42 });
        try aggregator.pushFrame(.{ .name = "parent_name", .filename = "/path/to/parent", .line = 67 });
        try aggregator.finalizeTrace(1);
    }

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try aggregator.dump(&writer);
    try writer.flush();

    try std.testing.expectStringStartsWith(buffer[0..], "thread 1;function_name (/path/to/filename:42);parent_name (/path/to/parent:67) 4\n");
}
