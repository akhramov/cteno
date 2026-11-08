const std = @import("std");

const Allocator = std.mem.Allocator;
const GnuHashSection64 = std.DynLib.ElfDynLib.GnuHashSection64;
const elf = std.elf;

const c = @import("c");

const ProcessMemory = @import("./process_memory.zig");
const ProcMaps = @import("./procmaps.zig");

process_memory: *ProcessMemory,
proc_maps: *ProcMaps,
allocator: Allocator,

pub fn init(process_memory: anytype, proc_maps: anytype, allocator: Allocator) @This() {
    return .{
        .process_memory = process_memory,
        .proc_maps = proc_maps,
        .allocator = allocator,
    };
}

pub fn run(self: @This(), symbol: []const u8) !?usize {
    while (try self.proc_maps.next()) |base| {
        self.process_memory.rebase(base);

        const ehdr = try self.process_memory.reader.takeStructPointer(elf.Elf64.Ehdr);

        if (!std.mem.eql(u8, &ehdr.ident.magic, elf.MAGIC)) {
            continue;
        }

        const optional_header = try findHeaderWithType(&self.process_memory.reader, ehdr.phnum, elf.PT.DYNAMIC);

        if (optional_header) |header| {
            self.process_memory.seekTo(header.vaddr);
            if (try walkSymtab(self.process_memory, symbol, self.allocator)) |result| {
                return result;
            }
        }
    }

    return null;
}

const ElfSymtab = struct {
    // symbols count
    count: usize,
    // offset of strtab dynamic tag
    strtab_offset: [*]u8,
    // offset of symtab dynamic tag
    offset: *const u8,

    fn init(process_memory: anytype, allocator: Allocator) !?@This() {
        var maybe_offset: ?*const u8 = null;
        var maybe_strtab_offset: ?[*]u8 = null;
        var maybe_count: ?usize = null;

        while (elf.takeDynamicSection(&process_memory.reader, true, .native)) |section| {
            switch (section.d_tag) {
                elf.DT_NULL => return null,
                elf.DT_SYMTAB => {
                    maybe_offset = @ptrFromInt(section.d_val);
                },
                elf.DT_STRTAB => {
                    maybe_strtab_offset = @ptrFromInt(section.d_val);
                },
                elf.DT_GNU_HASH => {
                    const position = process_memory.currentOffset();

                    process_memory.seekTo(@as(*const u8, @ptrFromInt(section.d_val)));
                    const hash = try GnuHash.init(&process_memory.reader, allocator);
                    defer hash.deinit();

                    maybe_count = hash.symbolsCount();

                    process_memory.seekTo(position);
                },
                else => continue,
            }

            if (maybe_offset) |offset| if (maybe_strtab_offset) |strtab_offset| if (maybe_count) |count| {
                return .{
                    .count = count,
                    .strtab_offset = strtab_offset,
                    .offset = offset,
                };
            };
        } else |err| return err;

        return null;
    }
};

fn walkSymtab(process_memory: anytype, symbol: []const u8, allocator: Allocator) !?usize {
    const symtab = try ElfSymtab.init(process_memory, allocator) orelse return null;
    process_memory.seekTo(symtab.offset);

    var i: usize = 0;

    while (i < symtab.count) : (i += 1) {
        const entry = try process_memory.reader.takeStruct(elf.Elf64.Sym, .native);

        const position = process_memory.currentOffset();
        const strtab_offset: *const u8 = &symtab.strtab_offset[entry.name];
        process_memory.seekTo(strtab_offset);

        const slice = try process_memory.reader.takeDelimiterExclusive(0);

        if (std.mem.eql(u8, slice, symbol)) {
            return entry.value;
        }

        process_memory.seekTo(position);
    }

    return null;
}

fn findHeaderWithType(reader: *std.Io.Reader, count: usize, header_type: elf.PT) !?elf.Elf64.Phdr {
    var i = count;

    while (i > 0) : (i -= 1) {
        const phdr = try elf.takeProgramHeader(reader, true, .native);

        if (phdr.type == header_type) {
            return phdr;
        }
    }

    return null;
}

const GnuHash = struct {
    header: elf.gnu_hash.Header,
    bloom: []u64,
    buckets: []u32,
    chains: []elf.gnu_hash.ChainEntry,

    allocator: Allocator,

    fn init(reader: *std.Io.Reader, allocator: Allocator) !GnuHash {
        const header = try reader.takeStruct(elf.gnu_hash.Header, .native);

        const bloom = try reader.readSliceEndianAlloc(allocator, u64, header.bloom_size, .native);
        errdefer allocator.free(bloom);

        var buckets = try reader.readSliceEndianAlloc(allocator, u32, header.nbuckets, .native);
        errdefer allocator.free(buckets);

        std.mem.sort(u32, buckets, {}, std.sort.asc(u32));
        const first_bucket = std.mem.findScalar(u32, buckets, header.symoffset) orelse buckets.len;
        const non_empty_buckets = buckets[first_bucket..];

        var chains: []elf.gnu_hash.ChainEntry = try allocator.alloc(elf.gnu_hash.ChainEntry, 128);
        errdefer allocator.free(chains);

        var chains_observed: usize = 0;
        var i: usize = 0;

        while (reader.takeStruct(elf.gnu_hash.ChainEntry, .native)) |chain_entry| {
            if (chain_entry.end_of_chain) {
                chains_observed += 1;
            }

            chains[i] = chain_entry;

            i += 1;
            if (i % 128 == 0) {
                chains = try allocator.realloc(chains, i + 128);
            }

            if (chains_observed == non_empty_buckets.len) {
                break;
            }
        } else |err| return err;

        chains = try allocator.realloc(chains, i);

        return .{
            .header = header,
            .bloom = bloom,
            .buckets = buckets,
            .chains = chains,

            .allocator = allocator,
        };
    }

    fn deinit(self: *const GnuHash) void {
        self.allocator.free(self.buckets);
        self.allocator.free(self.chains);
        self.allocator.free(self.bloom);
    }

    fn symbolsCount(self: GnuHash) usize {
        var symbols_in_chains: usize = 0;

        for (self.chains) |item| {
            if (item.hash > 0) {
                symbols_in_chains += 1;
            }
        }

        return self.header.symoffset + symbols_in_chains;
    }
};

test walkSymtab {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    var writer = std.Io.Writer.fixed(buf);

    // SYMTAB, STRTAB
    try writer.writeStruct(elf.Elf64_Dyn{
        .d_tag = elf.DT_SYMTAB,
        .d_val = 11,
    }, .native);
    try writer.writeStruct(elf.Elf64_Dyn{
        .d_tag = elf.DT_STRTAB,
        .d_val = 13,
    }, .native);

    // GNU HASH
    try writer.writeStruct(elf.Elf64_Dyn{
        .d_tag = elf.DT_GNU_HASH,
        .d_val = 7,
    }, .native);

    try writer.writeStruct(elf.gnu_hash.Header{
        .nbuckets = 1,
        .bloom_shift = 1,
        .bloom_size = 1,
        .symoffset = 0,
    }, .native);

    try writer.writeInt(u64, std.math.maxInt(u64), .native); // bloom, all ones, 100% positive.
    try writer.writeInt(u32, 0, .native); // chain index
    // if we actually want to use the bloom filter we would need
    // to compute the hash properly
    try writer.writeStruct(elf.gnu_hash.ChainEntry{
        .hash = 1,
        .end_of_chain = true,
    }, .native);

    // Our symbol and its name
    var symbol = std.mem.zeroes(elf.Elf64.Sym);
    symbol.name = 17;
    symbol.value = 191;
    try writer.writeStruct(symbol, .native);
    try writer.writeSliceEndian(u8, &[_]u8{ 95, 104, 111, 112, 101, 0 }, .native);

    const ProcessMemoryMock = struct {
        reader: std.Io.Reader,
        visited: std.ArrayList(usize),

        fn init(buffer: []u8, alloc: Allocator) !@This() {
            return .{
                .reader = std.Io.Reader.fixed(buffer),
                .visited = try std.ArrayList(usize).initCapacity(alloc, 5),
            };
        }

        fn seekTo(self: *@This(), item: anytype) void {
            const converted = switch (@typeInfo(@TypeOf(item))) {
                .pointer => @intFromPtr(item),
                .int => item,
                else => unreachable,
            };

            self.visited.appendAssumeCapacity(converted);
        }

        fn currentOffset(_: *@This()) usize {
            return 0;
        }
    };

    var process_memory = try ProcessMemoryMock.init(buf, allocator);
    defer process_memory.visited.deinit(allocator);

    const result = try walkSymtab(&process_memory, "_hope", allocator);

    try std.testing.expectEqual(result, symbol.value);
    // 7 -> reading GNU HASH
    // 0 -> jump back (current offset)
    // 11 -> starting symtab iteration
    // 30 -> strtab address (13) + symbol.name (17), aka &strtab[symbol.name]
    try std.testing.expectEqualSlices(usize, process_memory.visited.items, &[_]usize{ 7, 0, 11, 30 });

    var another_process_memory = try ProcessMemoryMock.init(buf, allocator);
    defer another_process_memory.visited.deinit(allocator);
    const notFound = try walkSymtab(&another_process_memory, "_despair", allocator);
    try std.testing.expectEqual(notFound, null);
}
