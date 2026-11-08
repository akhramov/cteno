const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c");
const Self = @This();

const Error = error{
    ReadError,
};

io: std.Io,
file: std.Io.File,
current_map: usize,

pub fn init(io: std.Io, pid: std.c.pid_t, allocator: Allocator) !Self {
    const path = try allocator.print("/proc/{}/maps", .{pid});
    defer allocator.free(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});

    return .{
        .file = file,
        .io = io,
        .current_map = 0,
    };
}

pub fn deinit(self: *const Self) void {
    self.file.close(self.io);
}

pub fn next(self: *Self) !?[*]const u8 {
    var query = c.struct_procmap_query{
        .size = @sizeOf(c.struct_procmap_query),
        .query_flags = c.PROCMAP_QUERY_COVERING_OR_NEXT_VMA | c.PROCMAP_QUERY_FILE_BACKED_VMA,
        .query_addr = self.current_map,
        .vma_start = 0,
        .vma_end = 0,
        .vma_flags = 0,
        .vma_page_size = 0,
        .vma_offset = 0,
        .inode = 0,
        .dev_major = 0,
        .dev_minor = 0,
        .vma_name_size = 0,
        .build_id_size = 0,
        .vma_name_addr = 0,
        .build_id_addr = 0,
    };

    const err = std.os.linux.ioctl(self.file.handle, c.PROCMAP_QUERY, @intFromPtr(&query));

    switch (std.posix.errno(err)) {
        .SUCCESS => {
            self.current_map = query.vma_end + 1;
            return @ptrFromInt(query.vma_start);
        },
        else => return Error.ReadError,
    }
}
