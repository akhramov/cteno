/// Aggregates the traces for the folded flamegraph representation
const std = @import("std");

const Allocator = std.mem.Allocator;
const Self = @This();
const Writer = std.Io.Writer;

traces: std.HashMap(Trace, usize, TraceContext, 80), // TODO: use radix tree for more compact representation.
allocator: Allocator,
accumulator: std.ArrayList(Frame),

const Frame = struct {
    name: []const u8,
    filename: []const u8,
    line: i32,
};

const Trace = struct {
    thread: u64,
    frames: std.ArrayList(Frame),
};

const TraceContext = struct {
    pub fn hash(_: @This(), t: Trace) u64 {
        var result: u64 = 0;

        for (t.frames.items) |frame| {
            std.debug.assert(frame.line > 0);
            const line: u64 = @intCast(frame.line);
            result ^= line + std.hash.Wyhash.hash(t.thread, frame.filename);
        }

        return result;
    }
    pub fn eql(_: @This(), a: Trace, b: Trace) bool {
        if (a.thread != b.thread) {
            return false;
        }

        if (a.frames.items.len != b.frames.items.len) {
            return false;
        }

        for (a.frames.items, b.frames.items) |a_frame, b_frame| {
            if (a_frame.line != b_frame.line) {
                return false;
            }

            if (!std.mem.eql(u8, a_frame.filename, b_frame.filename)) {
                return false;
            }
        }

        return true;
    }
};

/// Initialises the aggregator
pub fn init(allocator: Allocator) !Self {
    return .{
        .traces = .init(allocator),
        .allocator = allocator,
        .accumulator = try .initCapacity(allocator, 16),
    };
}

pub fn pushFrame(self: *Self, frame: Frame) !void {
    const frame_dup = Frame{
        .filename = try self.allocator.dupe(u8, frame.filename),
        .name = try self.allocator.dupe(u8, frame.name),
        .line = frame.line,
    };

    try self.accumulator.append(self.allocator, frame_dup);
}

/// Tag holds the traces root
pub fn finalizeTrace(self: *Self, thread: u64) !void {
    const key = Trace{
        .thread = thread,
        .frames = self.accumulator,
    };
    const entry = try self.traces.getOrPut(key);
    if (!entry.found_existing) {
        entry.value_ptr.* = 1;
        self.accumulator = try .initCapacity(self.allocator, 16);
    } else {
        entry.value_ptr.* = entry.value_ptr.* + 1;
        self.deinitFrames(self.accumulator.items);
        self.accumulator.clearAndFree(self.allocator);
    }
}

fn deinitFrames(self: *Self, frames: []Frame) void {
    for (frames) |frame| {
        self.allocator.free(frame.name);
        self.allocator.free(frame.filename);
    }
}

pub fn deinit(self: *Self) void {
    self.accumulator.deinit(self.allocator);

    var keyIter = self.traces.keyIterator();
    while (keyIter.next()) |key| {
        self.deinitFrames(key.frames.items);
        key.frames.deinit(self.allocator);
    }

    self.traces.deinit();
}

pub fn dumpAsCollapsed(self: Self, writer: *Writer) !void {
    var iter = self.traces.iterator();

    while (iter.next()) |item| {
        const val = item.value_ptr.*;
        const key = item.key_ptr.*;

        try writer.print("thread {}", .{key.thread});

        for (key.frames.items) |frame| {
            try writer.print(";{s} ({s}:{})", .{ frame.name, frame.filename, frame.line });
        }

        try writer.print(" {d}\n", .{val});
    }
}

test init {
    const allocator = std.testing.allocator;
    var aggregator = try init(allocator);
    defer aggregator.deinit();

    for (0..4) |_| {
        try aggregator.pushFrame(.{ .name = "function_name", .filename = "/path/to/filename", .line = 42 });
        try aggregator.pushFrame(.{ .name = "parent_name", .filename = "/path/to/parent", .line = 67 });
        try aggregator.finalizeTrace(1);
    }

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try aggregator.dumpAsCollapsed(&writer);
    try writer.flush();

    try std.testing.expectStringStartsWith(buffer[0..], "thread 1;function_name (/path/to/filename:42);parent_name (/path/to/parent:67) 4\n");
}
