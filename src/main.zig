const std = @import("std");

const lzw = @import("lzw.zig");

const ArrayList = std.ArrayList;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // var file = try std.fs.cwd().openFile("test_data/compressed/97", .{});
    // defer file.close();
    // var decoder = try lzw.decoder(allocator, file.reader());
    // defer decoder.deinit();
    // const data = try decoder.reader().readAllAlloc(allocator, 1000000);
    // defer allocator.free(data);
    // std.debug.print("{s}\n", .{data});

    var compressed_dir = try std.fs.cwd().openIterableDir("test_data/compressed", .{});
    defer compressed_dir.close();

    var decompressed_dir = try std.fs.cwd().openDir("test_data/decompressed", .{});
    defer decompressed_dir.close();

    var walker = try compressed_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |walker_entry| {
        std.debug.print("starting {s}\n", .{walker_entry.basename});
        
        var compressed_file = try compressed_dir.dir.openFile(walker_entry.basename, .{});
        defer compressed_file.close();

        var decompressed_file = try decompressed_dir.openFile(walker_entry.basename, .{});
        defer decompressed_file.close();

        var decoder = try lzw.decoder(allocator, compressed_file.reader()); 
        defer decoder.deinit();

        var decoded_text = try decoder.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(decoded_text);

        var original_decompressed_text = try decompressed_file.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(original_decompressed_text);

        std.debug.print("{s}\n\n{s}\n", .{decoded_text, original_decompressed_text});
        std.debug.assert(std.mem.eql(u8, decoded_text, original_decompressed_text));
        // std.debug.print("{x}\n", .{decoded_text[decoded_text.len - 1]});
        // std.debug.print("{d}\n", .{decoded_text.len});
        // std.debug.print("{d}\n", .{original_decompressed_text.len});
        // for (0..decoded_text.len - 1) |i| {
        //     if (decoded_text[i] != original_decompressed_text[i]) {
        //         std.debug.print("difference at {d}\n", .{i});
        //         return;
        //     }
        // }
    }
}
