const std = @import("std");
const c = @import("c");

const Allocator = std.mem.Allocator;

const ProcessMemory = @import("./process_memory.zig");
const ProcMaps = @import("./procmaps.zig");
const SymbolLookup = @import("./symbol_lookup.zig");
const Python = @import("./python.zig");

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

    return run(init.io, pid, allocator);
}

test {
    std.testing.refAllDecls(@This());
}

fn run(io: std.Io, pid: i32, allocator: Allocator) !void {
    var proc_maps = try ProcMaps.init(io, pid, allocator);
    defer proc_maps.deinit();

    var process_memory = try ProcessMemory.init(pid, allocator);

    const lookup = SymbolLookup.init(&process_memory, &proc_maps, allocator);
    try Python.run(&process_memory, lookup);
}
