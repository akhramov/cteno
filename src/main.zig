const std = @import("std");
const c = @import("c");

const Allocator = std.mem.Allocator;

const ProcessMemory = @import("./process_memory.zig");
const ProcMaps = @import("./procmaps.zig");
const SymbolLookup = @import("./symbol_lookup.zig");
const Python = @import("./python.zig");
const TracesAggregator = @import("./traces_aggregator.zig");

const Error = error{
    PtraceAttach,
    ReadMemory,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const pid = try std.fmt.parseInt(i32, args[1], 10);
    var buffer: [160 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    return run(init, pid, allocator);
}

test {
    std.testing.refAllDecls(@This());
}

fn run(init: std.process.Init, pid: i32, allocator: Allocator) !void {
    var proc_maps = try ProcMaps.init(init.io, pid, allocator);
    defer proc_maps.deinit();

    var traces_aggregator = try TracesAggregator.init(allocator);
    defer traces_aggregator.deinit();

    var process_memory = try ProcessMemory.init(pid, allocator);
    defer process_memory.deinit();

    const lookup = SymbolLookup.init(&process_memory, &proc_maps, allocator);
    var python = try Python.init(allocator, &process_memory, lookup, &traces_aggregator);

    try python.run();

    const buffer = try allocator.alloc(u8, 400);
    defer allocator.free(buffer);

    const stderr = init.preopens.get("stderr").?.file;
    var writer = stderr.writer(init.io, buffer);

    try traces_aggregator.dumpAsCollapsed(&writer.interface);
    try writer.flush();
}
