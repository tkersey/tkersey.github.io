const std = @import("std");

const site = @import("site.zig");
const server = @import("server.zig");
const watch = @import("watch.zig");

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
        var watch_enabled = true;
        var poll_ms: u64 = 250;
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.eql(u8, arg, "--host")) {
                idx += 1;
                if (idx >= args.len) {
                    try stderr.writeAll("error: --host requires a value\n\n");
                    try printUsage(stderr);
                    return 2;
                }
                host = args[idx];
            } else if (std.mem.eql(u8, arg, "--port")) {
                idx += 1;
                if (idx >= args.len) {
                    try stderr.writeAll("error: --port requires a value\n\n");
                    try printUsage(stderr);
                    return 2;
                }
                port = std.fmt.parseInt(u16, args[idx], 10) catch {
                    try stderr.print("error: invalid port '{s}'\n\n", .{args[idx]});
                    try printUsage(stderr);
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "--no-watch")) {
                watch_enabled = false;
            } else if (std.mem.eql(u8, arg, "--poll-ms")) {
                idx += 1;
                if (idx >= args.len) {
                    try stderr.writeAll("error: --poll-ms requires a value\n\n");
                    try printUsage(stderr);
                    return 2;
                }
                poll_ms = std.fmt.parseInt(u64, args[idx], 10) catch {
                    try stderr.print("error: invalid poll interval '{s}'\n\n", .{args[idx]});
                    try printUsage(stderr);
                    return 2;
                };
                if (poll_ms == 0) {
                    try stderr.writeAll("error: --poll-ms must be > 0\n\n");
                    try printUsage(stderr);
                    return 2;
                }
            } else {
                try stderr.print("error: unknown argument '{s}'\n\n", .{arg});
                try printUsage(stderr);
                return 2;
            }
        }

        try site.generate(allocator, base_dir, .{});
        try stdout.print("Serving dist/ at http://{s}:{d}/\n", .{ host, port });
        if (watch_enabled) {
            const poll_ns = poll_ms * std.time.ns_per_ms;
            const thread_args: WatchThreadArgs = .{
                .base_dir = base_dir,
                .poll_interval_ns = poll_ns,
                .targets = .{},
            };
            const thread = try std.Thread.spawn(.{}, watchThreadMain, .{thread_args});
            thread.detach();
            try stdout.print("Watching for changes (polling every {d}ms)\n", .{poll_ms});
        }
        try server.serve(base_dir, .{ .host = host, .port = port });
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
        \\  blog serve [--host 127.0.0.1] [--port 8080] [--no-watch] [--poll-ms 250]
        \\  blog help
        \\
        \\Zig build steps:
        \\  zig build         # generate dist/
        \\  zig build serve   # generate + serve dist/
        \\  zig build test
        \\
    );
}

const WatchThreadArgs = struct {
    base_dir: std.fs.Dir,
    poll_interval_ns: u64,
    targets: watch.WatchTargets,
};

fn watchThreadMain(args: WatchThreadArgs) void {
    const allocator = std.heap.c_allocator;

    var base_dir = args.base_dir.openDir(".", .{ .iterate = true }) catch |err| {
        std.log.err("watch: open base dir failed: {s}", .{@errorName(err)});
        return;
    };
    defer base_dir.close();

    var prev = watch.fingerprint(allocator, base_dir, args.targets) catch |err| {
        std.log.err("watch: initial fingerprint failed: {s}", .{@errorName(err)});
        return;
    };

    while (true) {
        std.Thread.sleep(args.poll_interval_ns);

        const next = watch.fingerprint(allocator, base_dir, args.targets) catch |err| {
            std.log.err("watch: fingerprint failed: {s}", .{@errorName(err)});
            continue;
        };
        if (next == prev) continue;
        prev = next;

        std.log.info("Change detected; rebuilding...", .{});
        site.generate(allocator, base_dir, .{}) catch |err| {
            std.log.err("Rebuild failed: {s}", .{@errorName(err)});
            continue;
        };
        std.log.info("Rebuild complete.", .{});
    }
}

test "serve arg parsing rejects missing values" {
    const testing = std.testing;

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);

    const stdout_writer = stdout_buf.writer(testing.allocator);
    const stderr_writer = stderr_buf.writer(testing.allocator);

    const args = [_][]const u8{ "blog", "serve", "--port" };
    const exit_code = try run(testing.allocator, std.fs.cwd(), &args, stdout_writer, stderr_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Usage:") != null);
}
