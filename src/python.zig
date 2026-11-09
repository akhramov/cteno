const std = @import("std");

const Allocator = std.mem.Allocator;

const python_3_15 = @import("3_15");
const python_3_14 = @import("3_14");

const SymbolLookup = @import("./symbol_lookup.zig");
const ProcessMemory = @import("./process_memory.zig");
const ProcMaps = @import("./procmaps.zig");

const DebugOffsetsHeader = extern struct {
    cookie: [8]u8,
    version: u64,
};

const Error = error{
    NotPython,
};

pub fn run(process_memory: *ProcessMemory, symbol_lookup: SymbolLookup) !void {
    const address = try symbol_lookup.run("_PyRuntime") orelse return Error.NotPython;

    process_memory.seekTo(address);

    const header = try process_memory.reader.peekStruct(DebugOffsetsHeader, .native);

    if (!std.mem.eql(u8, &header.cookie, "xdebugpy")) {
        return Error.NotPython;
    }

    _ = switch (header.version >> 16) {
        python_3_15.PY_VERSION_HEX >> 16 => try doRun(python_3_15, address, process_memory),
        python_3_14.PY_VERSION_HEX >> 16 => try doRun(python_3_14, address, process_memory),
        else => return Error.NotPython,
    };
}

fn doRun(interpreter: anytype, address: usize, process_memory: *ProcessMemory) !void {
    const offsets = try process_memory.reader.takeStruct(interpreter.struct__Py_DebugOffsets, .native);
    process_memory.seekTo(address + offsets.runtime_state.interpreters_head);
    const interpr_address = try process_memory.reader.peekInt(u64, .native);
    std.debug.assert(interpr_address > 0);

    var thread = try process_memory.digMemory(interpr_address, .{ interpreter.PyInterpreterState, "threads", "head" });
    while (true) {
        std.log.info("Thread {}, holds gil {}", .{ thread.id, thread.holds_gil });

        // Safety: races on a running process.
        var frame = try process_memory.digMemory(thread, .{ "current_frame" });

        while (true) {
            try collectFrameData(interpreter, frame, process_memory);

            frame = try process_memory.digMemory(frame, .{"previous"});

            if (frame.previous == null) {
                break;
            }
        }

        if (thread.next == null) {
            break;
        }

        thread = try process_memory.digMemory(thread, .{"next"});
    }
}

fn collectFrameData(interpreter: anytype, frame: interpreter._PyInterpreterFrame, process_memory: *ProcessMemory) !void {
    if (frame.owner != interpreter.FRAME_OWNED_BY_INTERPRETER) {
        const co = try process_memory.digMemory(frame, .{
            "f_executable", "bits", interpreter.PyCodeObject,
        });

        const code_ptr = try process_memory.digMemory(frame, .{ "f_executable", "bits", interpreter.PyCodeObject, .{ "co_code_adaptive", *const u8 } });

        const instruction_pointer: *const u8 = @ptrCast(frame.instr_ptr);

        const linetable_size = try process_memory.digMemory(co, .{ .{ "co_linetable", interpreter.PyBytesObject }, "ob_base", "ob_size" });

        const linetable = try process_memory.digMemory(co, .{ .{ "co_linetable", interpreter.PyBytesObject }, .{ "ob_sval", *const u8 } });

        process_memory.seekTo(linetable);
        const linetable_val = try process_memory.reader.peek(@intCast(linetable_size + 1));

        std.debug.assert(linetable_val[linetable_val.len - 1] == 0);

        var table = LinetableInfo.init(linetable_val, co.co_firstlineno);

        const addrq = (instruction_pointer - code_ptr) >> 1;

        const line_number = blk: while (try table.next(interpreter)) |res| {
            if (res.addr <= addrq and res.end_addr >= addrq) {
                break :blk res;
            }
        } else unreachable;

        _ = try process_memory.digMemory(co, .{.{ "co_qualname", interpreter.PyASCIIObject }});
        const qualname = try process_memory.reader.takeDelimiter(0) orelse "";

        std.log.info("function {s} located at:", .{qualname});

        _ = try process_memory.digMemory(co, .{.{ "co_filename", interpreter.PyASCIIObject }});
        const filename = try process_memory.reader.takeDelimiter(0) orelse "";

        std.log.info("{s}:{any}", .{ filename, line_number.line });
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
