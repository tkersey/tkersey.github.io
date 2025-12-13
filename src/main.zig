const std = @import("std");

const cli = @import("cli.zig");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const exit_code = cli.run(gpa, std.fs.cwd(), args, stdout, stderr) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    std.process.exit(exit_code);
}
