const std = @import("std");

const cli = @import("cli.zig");

pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    return cli.run(gpa, std.fs.cwd(), args, stdout, stderr) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
}
