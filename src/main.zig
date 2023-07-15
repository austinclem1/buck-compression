const std = @import("std");

const lzw = @import("lzw.zig");

const ArrayList = std.ArrayList;

pub fn main() !void {}

test "verify decompression" {
    const allocator = std.testing.allocator;

    const test_filenames = [_][]const u8{ "0", "1", "3", "16", "17", "32", "33", "34", "35", "48", "49", "50", "52", "64", "65", "66", "67", "80", "81", "82", "83", "94", "95", "96", "97", "98", "99" };

    inline for (test_filenames) |filename| {
        var compressed_file = try std.fs.cwd().openFile("test_data/compressed/" ++ filename, .{});
        defer compressed_file.close();

        var decompressed_file = try std.fs.cwd().openFile("test_data/decompressed/" ++ filename, .{});
        defer decompressed_file.close();

        var decoder = try lzw.decoder(allocator, compressed_file.reader());
        defer decoder.deinit();

        const decoded_text = try decoder.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(decoded_text);

        const original_text = try decompressed_file.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(original_text);

        try std.testing.expectEqualSlices(u8, original_text, decoded_text);
    }
}

test "verify compression" {
    const allocator = std.testing.allocator;

    // level id 97 intentionally left out for compression test because it includes a clear code
    // near the end when it starts encoding map data
    const test_filenames = [_][]const u8{ "0", "1", "3", "16", "17", "32", "33", "34", "35", "48", "49", "50", "52", "64", "65", "66", "67", "80", "81", "82", "83", "94", "95", "96", "98", "99" };

    inline for (test_filenames) |filename| {
        var compressed_file = try std.fs.cwd().openFile("test_data/compressed/" ++ filename, .{});
        defer compressed_file.close();

        var decompressed_file = try std.fs.cwd().openFile("test_data/decompressed/" ++ filename, .{});
        defer decompressed_file.close();

        const input_text = try decompressed_file.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(input_text);

        var newly_compressed_text = std.ArrayList(u8).init(allocator);
        defer newly_compressed_text.deinit();

        var encoder = try lzw.encoder(allocator, newly_compressed_text.writer());
        defer encoder.deinit();

        try encoder.writer().writeAll(input_text);
        try encoder.endStream();
        const newly_compressed_text_trimmed = std.mem.trimRight(u8, newly_compressed_text.items, "\x00");

        const original_compressed_text = try compressed_file.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(original_compressed_text);
        const original_compressed_text_trimmed = std.mem.trimRight(u8, original_compressed_text, "\x00");

        try std.testing.expectEqualSlices(u8, original_compressed_text_trimmed, newly_compressed_text_trimmed);
    }
}
