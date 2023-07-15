const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub fn Decoder(comptime InStream: type) type {
    return struct {
        const Self = @This();

        const Error = BitReaderType.Error || Allocator.Error || error{ ReachedPrefixLengthLimit };
        const Reader = std.io.Reader(*Self, Error, read);

        arena: ArenaAllocator,
        in_reader: BitReaderType,
        out_buffer: ArrayListUnmanaged(u8),
        decode_stack: ArrayListUnmanaged(u8),
        dict: MultiArrayList(DictEntry),
        
        code_width: u8 = initial_code_width,
        last_code: ?u16 = null,
        decoded_byte_count: usize = 0,
        done_decoding: bool = false,

        const initial_code_width = 9;
        const max_code_width = 12;
        const max_prefix_len = 0x1000;
        const clear_code = 0x100;
        const end_code = 0x101;
        const dict_max_len = maxIntForWidthUnsigned(max_code_width);

        const BitReaderType = std.io.BitReader(.Big, InStream);

        const DictEntry = struct {
            prefix: u16,
            suffix: u8,
        };

        pub fn init(backing_allocator: Allocator, in_stream: InStream) Allocator.Error!Self {
            var d = Self {
                .arena = ArenaAllocator.init(backing_allocator),
                .in_reader = std.io.bitReader(.Big, in_stream),
                .out_buffer = .{},
                .decode_stack = .{},
                .dict = .{},
            };
            errdefer d.arena.deinit();
            
            const dict_initial_len = maxIntForWidthUnsigned(initial_code_width);
            try d.dict.ensureTotalCapacity(d.arena.allocator(), dict_initial_len);
            
            for (0..0x100) |i| {
                d.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = @intCast(i) });
            }
            // append dummy values for CLEAR and END codes
            d.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });
            d.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });
            
            return d;
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        pub fn read(self: *Self, dst: []u8) Error!usize {
            while (self.out_buffer.items.len < dst.len and !self.done_decoding) {
                try self.decodeCode();
            }

            var items = self.out_buffer.items;
            const n = @min(items.len, dst.len);

            @memcpy(dst[0..n], items[0..n]);
            // shift remaining items in out_buffer to beginning
            std.mem.copyForwards(u8, items[0..items.len - n], items[n..]);
            self.out_buffer.shrinkRetainingCapacity(items.len - n);

            return n;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        // returns number of bytes decoded
        pub fn decodeCode(self: *Self) Error!void {
            if (self.done_decoding) {
                return;
            }
            
            const code = try self.readCode();
            // std.debug.assert(code <= self.dict.len);

            if (code == end_code) {
                // if (self.decoded_byte_count % 2 == 1) {
                //     try self.out_buffer.append(self.arena.allocator(), 0);
                //     self.decoded_byte_count += 1;
                // }
                self.done_decoding = true;
                return;
            }

            if (code == clear_code) {
                self.dict.shrinkRetainingCapacity(end_code + 1);
                self.code_width = initial_code_width;
                self.last_code = null;
                return;
            }

            if (self.last_code == null) {
                try self.out_buffer.append(self.arena.allocator(), @intCast(code));
                self.decoded_byte_count += 1;
                self.last_code = code;
                return;
            }
            
            var index: u16 = blk: {
                if (code >= self.dict.len) {
                    const prev_suffix = self.dict.items(.suffix)[self.dict.len - 1];
                    try self.decode_stack.append(self.arena.allocator(), prev_suffix);
                    break :blk self.last_code.?;
                } else {
                    break :blk code;
                }
            };
            
            while (index > 0xff) {
                const ch = self.dict.items(.suffix)[index];
                
                if (self.decode_stack.items.len >= max_prefix_len) {
                    return error.ReachedPrefixLengthLimit;
                }
                try self.decode_stack.append(self.arena.allocator(), ch);
                
                index = self.dict.items(.prefix)[index];
            }
            try self.decode_stack.append(self.arena.allocator(), @intCast(index));
            const new_suffix = self.decode_stack.getLast();

            try self.out_buffer.ensureUnusedCapacity(self.arena.allocator(), self.decode_stack.items.len);
            self.decoded_byte_count += self.decode_stack.items.len;
            while (self.decode_stack.popOrNull()) |ch| {
                self.out_buffer.appendAssumeCapacity(ch);
            }

            if (self.dict.len < dict_max_len) {
                self.dict.appendAssumeCapacity(.{ .prefix = self.last_code.?, .suffix = new_suffix });

                const code_widening_threshold = maxIntForWidthUnsigned(self.code_width);
                const should_widen_code = self.dict.len == code_widening_threshold and self.code_width < max_code_width;
                if (should_widen_code) {
                    self.code_width += 1;
                    const new_dict_capacity = maxIntForWidthUnsigned(self.code_width);
                    try self.dict.ensureTotalCapacity(self.arena.allocator(), new_dict_capacity);
                }
            }
            
            self.last_code = code;
        }
        
        fn readCode(self: *Self) BitReaderType.Error!u16 {
            var bits_read: usize = 0;
            var code = try self.in_reader.readBits(u16, self.code_width - 1, &bits_read);
            
            const might_index_upper_dict = blk: {
                const mask = (@as(u16, 1) << @intCast(self.code_width - 1)) - 1;
                const masked_dict_len = self.dict.len & mask;
                break :blk code <= masked_dict_len;
            };

            if (might_index_upper_dict) {
                const most_sig_bit = try self.in_reader.readBits(u1, 1, &bits_read);
                const most_sig_bit_shifted = @as(u16, most_sig_bit) << @intCast(self.code_width - 1);
                code |= most_sig_bit_shifted;
            }

            return code;
        }
    
        pub fn debugPrintDict(self: *const Self) void {
            var i: usize = end_code + 1;
            while (i < self.dict.len) : (i += 0x10) {
                const start = i;
                const end = @min(i + 0x10, self.dict.len);
                
                std.debug.print("0x{x:0>3}:\n", .{start});
                for (self.dict.items(.suffix)[start..end]) |s| {
                    if (std.ascii.isPrint(s)) {
                        std.debug.print("\'{c}\' ", .{s});
                    } else {
                        std.debug.print("{x:0>3} ", .{s});
                    }
                }
                std.debug.print("\n", .{});
                for (self.dict.items(.prefix)[start..end]) |p| {
                    if (p < 128 and std.ascii.isPrint(@intCast(p))) {
                        std.debug.print("\'{c}\' ", .{@as(u8, @intCast(p))});
                    } else {
                        std.debug.print("{x:0>3} ", .{p});
                    }
                }
                std.debug.print("\n\n", .{});
            }
        }

        fn maxIntForWidthUnsigned(width: usize) usize {
            return (@as(usize, 1) << @intCast(width)) - 1;
        }
    };
}

pub fn decoder(allocator: Allocator, in_stream: anytype) !Decoder(@TypeOf(in_stream)) {
    return Decoder(@TypeOf(in_stream)).init(allocator, in_stream);
}


pub fn Encoder(comptime OutStream: type) type {
    return struct {
        arena: ArenaAllocator,
        out_writer: BitWriterType,
        dict: MultiArrayList(DictEntry),
        code_width: u8 = initial_code_width,
        cur_prefix: u16 = 0,
        on_first_byte: bool = true,

        const initial_code_width = 9;
        const max_code_width = 12;
        const clear_code = 0x100;
        const end_code = 0x101;
        const dict_max_len = (@as(u16, 1) << @intCast(max_code_width)) - 1;

        const Self = @This();

        const Error = Allocator.Error || BitWriterType.Error;
        const Writer = std.io.Writer(*Self, Error, write);
        
        const BitWriterType = std.io.BitWriter(.Big, OutStream);

        const DictEntry = struct {
            prefix: u16,
            suffix: u8,
        };

        pub fn init(backing_allocator: Allocator, out_stream: OutStream) Allocator.Error!Self {
            var e = Self {
                .arena = ArenaAllocator.init(backing_allocator),
                .out_writer = std.io.bitWriter(.Big, out_stream),
                .dict = .{},
            };
            errdefer e.arena.deinit();

            try e.dict.ensureUnusedCapacity(e.arena.allocator(), end_code + 1);
            for (0..0x100) |i| {
                e.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = @intCast(i) });
            }
            // add dummy entries for CLEAR and END codes
            e.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });
            e.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });

            return e;
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        pub fn write(self: *Self, input: []const u8) Error!usize {
            for (input) |ch| {
                if (self.on_first_byte) {
                    self.on_first_byte = false;
                    self.cur_prefix = ch;
                    continue;
                }
                
                if (self.indexOfMatchingEntry(self.cur_prefix, ch)) |match| {
                    self.cur_prefix = match;
                } else {
                    try self.emitCode(self.cur_prefix);
                    try self.maybeUpdateDictAndCodeWidth(ch);
                    self.cur_prefix = ch;
                }
            }

            return input.len;
        }
        
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
        
        pub fn endStream(self: *Self) BitWriterType.Error!void {
            try self.emitCode(self.cur_prefix);
            try self.emitCode(end_code);
            try self.out_writer.flushBits();
        }

        fn emitCode(self: *Self, code: u16) BitWriterType.Error!void {
            const lower_bits_mask = (@as(u16, 1) << @intCast(self.code_width - 1)) - 1;
            
            const dict_len_masked = (self.dict.len - 1) & lower_bits_mask;
            const code_masked = code & lower_bits_mask;
            
            try self.out_writer.writeBits(code_masked, self.code_width - 1);
            if (code_masked <= dict_len_masked) {
                const most_sig_bit = getBitAt(code, @intCast(self.code_width - 1));
                try self.out_writer.writeBits(most_sig_bit, 1);
            }
        }

        fn maybeUpdateDictAndCodeWidth(self: *Self, suffix: u8) Allocator.Error!void {
            if (self.dict.len >= dict_max_len) {
                return;
            }
            
            const new_entry = .{ .prefix = self.cur_prefix, .suffix = suffix };
            try self.dict.append(self.arena.allocator(), new_entry);

            const code_widening_threshold = (@as(u16, 1) << @intCast(self.code_width));
            if (self.dict.len >= code_widening_threshold and self.code_width < max_code_width) {
                self.code_width += 1;
            }
        }

        fn indexOfMatchingEntry(self: *Self, prefix: u16, suffix: u8) ?u16 {
            const dict_prefixes = self.dict.items(.prefix);
            const dict_suffixes = self.dict.items(.suffix);
            
            var i: u16 = @max(prefix + 1, end_code + 1);
            while (i < self.dict.len) : (i += 1) {
                if (dict_prefixes[i] == prefix and dict_suffixes[i] == suffix) {
                    return i;
                }
            }
            
            return null;
        }

        fn getBitAt(val: u16, index: u4) u1 {
            return @intCast((val >> index) & 1);
        }

        pub fn debugPrintDict(self: *const Self) void {
            var start: usize = end_code + 1;
            while (start < self.dict.len) : (start += 0x10) {
                const end = @min(start + 0x10, self.dict.len);
                
                std.debug.print("0x{x}:\n", .{start});
                for (self.dict.items(.suffix)[start..end]) |s| {
                    if (std.ascii.isPrint(s)) {
                        std.debug.print("\'{c}\' ", .{s});
                    } else {
                        std.debug.print("{x:0>3} ", .{s});
                    }
                }
                std.debug.print("\n", .{});
                
                for (self.dict.items(.prefix)[start..end]) |p| {
                    if (p < 128 and std.ascii.isPrint(@intCast(p))) {
                        std.debug.print("\'{c}\' ", .{@as(u8, @intCast(p))});
                    } else {
                        std.debug.print("{x:0>3} ", .{p});
                    }
                }
                std.debug.print("\n\n", .{});
            }
        }
    };
}

pub fn encoder(backing_allocator: Allocator, out_stream: anytype) Allocator.Error!Encoder(@TypeOf(out_stream)) {
    return Encoder(@TypeOf(out_stream)).init(backing_allocator, out_stream);
}

