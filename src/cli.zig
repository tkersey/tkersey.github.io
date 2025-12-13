const std = @import("std");

const site = @import("site.zig");
const server = @import("server.zig");

pub fn run(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len < 2) {
        try printUsage(stderr);
        return 2;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help")) {
        try printUsage(stdout);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "build")) {
        try site.generate(allocator, base_dir, .{});
        try stdout.print("Generated site in dist/\n", .{});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 8080;
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.eql(u8, arg, "--host")) {
                idx += 1;
                if (idx >= args.len) return error.InvalidArgs;
                host = args[idx];
            } else if (std.mem.eql(u8, arg, "--port")) {
                idx += 1;
                if (idx >= args.len) return error.InvalidArgs;
                port = try std.fmt.parseInt(u16, args[idx], 10);
            } else {
                return error.InvalidArgs;
            }
        }

        try site.generate(allocator, base_dir, .{});
        try stdout.print("Serving dist/ at http://{s}:{d}/\n", .{ host, port });
        try server.serve(allocator, base_dir, .{ .host = host, .port = port });
        return 0;
    }

    try stderr.print("error: unknown command '{s}'\n\n", .{cmd});
    try printUsage(stderr);
    return 2;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  blog build
        \\  blog serve [--host 127.0.0.1] [--port 8080]
        \\  blog help
        \\
        \\Zig build steps:
        \\  zig build         # generate dist/
        \\  zig build serve   # generate + serve dist/
        \\  zig build test
        \\
    );
}

test "serve arg parsing rejects missing values" {
    const testing = std.testing;

    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();

    const stdout_writer = stdout_buf.writer();
    const stderr_writer = stderr_buf.writer();

    const args = [_][]const u8{ "blog", "serve", "--port" };
    const result = run(testing.allocator, std.fs.cwd(), &args, stdout_writer, stderr_writer);
    try testing.expectError(error.InvalidArgs, result);
}
