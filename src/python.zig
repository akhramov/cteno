const std = @import("std");

const Allocator = std.mem.Allocator;

const python_3_15 = @import("3_15");
const python_3_14 = @import("3_14");

const SymbolLookup = @import("./symbol_lookup.zig");
const ProcessMemory = @import("./process_memory.zig");
const ProcMaps = @import("./procmaps.zig");
const TracesAggregator = @import("./traces_aggregator.zig");

const Self = @This();

const DebugOffsetsHeader = extern struct {
    cookie: [8]u8,
    version: u64,
};

const Error = error{
    NotPython,
};

allocator: Allocator,
version: u64,
interpr_address: usize,
process_memory: *ProcessMemory,
traces_aggregator: *TracesAggregator,

pub fn init(allocator: Allocator, process_memory: *ProcessMemory, symbol_lookup: SymbolLookup, traces_aggregator: *TracesAggregator) !Self {
    const address = try symbol_lookup.run("_PyRuntime") orelse return Error.NotPython;

    process_memory.seekTo(address);

    const header = try process_memory.reader.peekStruct(DebugOffsetsHeader, .native);

    if (!std.mem.eql(u8, &header.cookie, "xdebugpy")) {
        return Error.NotPython;
    }

    const interpreter_address = try dispatch(.{ .version = header.version, .address = address, .process_memory = process_memory }, struct {
        fn f(interpreter: anytype, ctx: anytype) anyerror!usize {
            return getInterpreterAddress(interpreter, ctx.address, ctx.process_memory);
        }
    }.f);

    return .{
        .allocator = allocator,
        .interpr_address = interpreter_address,
        .process_memory = process_memory,
        .version = header.version,
        .traces_aggregator = traces_aggregator,
    };
}

pub fn run(self: *Self) !void {
    try dispatch(.{ .version = self.version, .self = self }, struct {
        fn f(interpreter: anytype, ctx: anytype) anyerror!void {
            return ctx.self.doRun(interpreter);
        }
    }.f);
}

fn getInterpreterAddress(interpreter: anytype, debug_offests_address: usize, process_memory: *ProcessMemory) !usize {
    const offsets = try process_memory.reader.takeStruct(interpreter.struct__Py_DebugOffsets, .native);
    process_memory.seekTo(debug_offests_address + offsets.runtime_state.interpreters_head);
    const interpr_address = try process_memory.reader.peekInt(u64, .native); // OBS. pointer width assumption.
    std.debug.assert(interpr_address > 0);

    return interpr_address;
}

// we have vtables at home
fn dispatch(ctx: anytype, f: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    return switch (ctx.version >> 16) {
        python_3_15.PY_VERSION_HEX >> 16 => try f(python_3_15, ctx),
        python_3_14.PY_VERSION_HEX >> 16 => try f(python_3_14, ctx),
        else => return Error.NotPython,
    };
}

fn doRun(self: *Self, interpreter: anytype) !void {
    var thread = try self.process_memory.digMemory(self.interpr_address, .{ interpreter.PyInterpreterState, "threads", "head" });
    while (true) {
        std.log.info("Thread {}, holds gil {}", .{ thread.native_thread_id, thread.holds_gil });

        // Safety: races on a running process.
        var frame = try self.process_memory.digMemory(thread, .{"current_frame"});

        while (true) {
            try self.collectFrameData(interpreter, frame);

            frame = try self.process_memory.digMemory(frame, .{"previous"});

            if (frame.previous == null) {
                break;
            }
        }

        try self.traces_aggregator.finalizeTrace(thread.native_thread_id);
        if (thread.next == null) {
            break;
        }

        thread = try self.process_memory.digMemory(thread, .{"next"});
    }
}

fn collectFrameData(self: *Self, interpreter: anytype, frame: interpreter._PyInterpreterFrame) !void {
    if (frame.owner != interpreter.FRAME_OWNED_BY_INTERPRETER) {
        const co = try self.process_memory.digMemory(frame, .{
            "f_executable", "bits", interpreter.PyCodeObject,
        });

        const code_ptr = try self.process_memory.digMemory(frame, .{ "f_executable", "bits", interpreter.PyCodeObject, .{ "co_code_adaptive", *const u8 } });

        const instruction_pointer: *const u8 = @ptrCast(frame.instr_ptr);

        const linetable_size = try self.process_memory.digMemory(co, .{ .{ "co_linetable", interpreter.PyBytesObject }, "ob_base", "ob_size" });

        const linetable = try self.process_memory.digMemory(co, .{ .{ "co_linetable", interpreter.PyBytesObject }, .{ "ob_sval", *const u8 } });

        self.process_memory.seekTo(linetable);
        const linetable_val = try self.process_memory.reader.peek(@intCast(linetable_size + 1));

        std.debug.assert(linetable_val[linetable_val.len - 1] == 0);

        var table = LinetableInfo.init(linetable_val, co.co_firstlineno);

        const addrq = (instruction_pointer - code_ptr) >> 1;

        const location = blk: while (try table.next(interpreter)) |res| {
            if (res.addr <= addrq and res.end_addr >= addrq) {
                break :blk res;
            }
        } else unreachable;

        _ = try self.process_memory.digMemory(co, .{.{ "co_qualname", interpreter.PyASCIIObject }});
        const qualname =
            try self.allocator.dupe(u8, try self.process_memory.reader.takeDelimiter(0) orelse "");
        defer self.allocator.free(qualname);

        std.log.info("function {s} located at:", .{qualname});

        // In contrary to qualname, filename does not need to be duped, because
        // nothing overwrites the reader's buffer at this point.
        _ = try self.process_memory.digMemory(co, .{.{ "co_filename", interpreter.PyASCIIObject }});
        const filename = try self.process_memory.reader.takeDelimiter(0) orelse "";

        std.log.info("{s}:{any}", .{ filename, location.line });
        try self.traces_aggregator.pushFrame(.{
            .name = qualname,
            .filename = filename,
            .line = location.line,
        });
    }
}

/// Parses python linetables, needed for pointer instruction to
/// line numbers resolution.
/// Translated from https://github.com/python/cpython/blob/799fb621b864e28077bbc223abf1102162a46f09/Tools/gdb/libpython.py#L671
const LinetableInfo = struct {
    linetable: std.Io.Reader,
    /// address of current instruction
    address: i32,
    current_line_number: i32 = 0,

    const IteratorItem = struct {
        addr: i32,
        end_addr: i32,
        line: i32,
        end_line: ?i32,
        column: ?i32,
        end_column: ?i32,
    };

    fn init(linetable: []u8, first_line_no: i32) @This() {
        return .{
            .linetable = std.Io.Reader.fixed(linetable),
            .address = 0,
            .current_line_number = first_line_no,
        };
    }

    fn next(self: *@This(), interpreter: anytype) !?IteratorItem {
        const byte = try self.linetable.takeByte();

        const code = (byte >> 3) & 15;
        const length = (byte & 7) + 1;
        const end_addr = self.address + length;

        var result = IteratorItem{
            .addr = self.address,
            .end_addr = end_addr,
            .line = self.current_line_number,
            .end_line = null,
            .column = null,
            .end_column = null,
        };

        switch (code) {
            interpreter.PY_CODE_LOCATION_INFO_NONE => {},
            interpreter.PY_CODE_LOCATION_INFO_LONG => {
                const line_delta = try self.readSignedVarint();
                self.current_line_number += line_delta;

                result.line = self.current_line_number;
                result.end_line = self.current_line_number + try self.readVarint();
                result.column = try self.readVarint();
                result.end_column = try self.readVarint();
            },
            interpreter.PY_CODE_LOCATION_INFO_NO_COLUMNS => {
                const line_delta = try self.readSignedVarint();
                self.current_line_number += @intCast(line_delta);

                result.line = self.current_line_number;
            },
            interpreter.PY_CODE_LOCATION_INFO_ONE_LINE0, interpreter.PY_CODE_LOCATION_INFO_ONE_LINE1, interpreter.PY_CODE_LOCATION_INFO_ONE_LINE2 => {
                const line_delta = code - 10;
                self.current_line_number += @intCast(line_delta);

                result.line = self.current_line_number;
                result.column = try self.linetable.takeByte();
                result.end_column = try self.linetable.takeByte();
            },
            else => {
                std.debug.assert(code < 10);
                const second_byte = try self.linetable.takeByte();

                result.line = self.current_line_number;
                result.column = code << 3 | (second_byte >> 4);
                result.end_column = (code << 3 | (second_byte >> 4)) + (second_byte & 15);
            },
        }

        self.current_line_number = result.line;
        self.address = end_addr;

        return result;
    }

    fn readSignedVarint(self: *@This()) !i32 {
        const uval = try self.readVarint();

        if (uval & 1 != 0) {
            return -(uval >> 1);
        } else {
            return uval >> 1;
        }
    }

    fn readVarint(self: *@This()) !i32 {
        var b = try self.linetable.takeByte();
        var val = b & 63;
        var shift: u3 = 0;

        // Safety: we trust the profiled process.
        // otherwise the buffer will eventually run out or shift will overflow.
        // problematic when profiling a running process.
        while (b & 64 != 0) {
            b = try self.linetable.takeByte();
            shift += 6;
            val |= (b & 63) << shift;
        }

        return val;
    }
};
