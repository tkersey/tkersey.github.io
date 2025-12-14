const std = @import("std");

const site = @import("site.zig");
const server = @import("server.zig");
const watch = @import("watch.zig");

const site_config_path: []const u8 = "site.yml";

const SiteConfig = struct {
    raw: ?[]u8 = null,

    title: []const u8 = "Blog",
    description: []const u8 = "",
    author: ?[]const u8 = null,
    base_url: []const u8 = "https://tkersey.github.io",
    posts_dir: []const u8 = "posts",
    static_dir: []const u8 = "static",
    dist_dir: []const u8 = "dist",

    pub fn deinit(self: *SiteConfig, allocator: std.mem.Allocator) void {
        if (self.raw) |buf| allocator.free(buf);
    }
};

fn loadSiteConfig(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !SiteConfig {
    const raw = base_dir.readFileAlloc(allocator, site_config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    errdefer allocator.free(raw);

    var config: SiteConfig = .{ .raw = raw };

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trimRight(u8, trimmed[0..colon], " \t");
        var value = std.mem.trimLeft(u8, trimmed[colon + 1 ..], " \t");
        value = stripInlineComment(value);
        const scalar = parseScalar(value);
        if (scalar.len == 0) continue;

        if (std.mem.eql(u8, key, "title")) config.title = scalar;
        if (std.mem.eql(u8, key, "description")) config.description = scalar;
        if (std.mem.eql(u8, key, "author")) config.author = scalar;
        if (std.mem.eql(u8, key, "base_url")) config.base_url = scalar;
        if (std.mem.eql(u8, key, "posts_dir")) config.posts_dir = scalar;
        if (std.mem.eql(u8, key, "static_dir")) config.static_dir = scalar;
        if (std.mem.eql(u8, key, "dist_dir")) config.dist_dir = scalar;
    }

    return config;
}

fn generateFromConfig(allocator: std.mem.Allocator, base_dir: std.fs.Dir, log_warnings: bool) !void {
    var config = try loadSiteConfig(allocator, base_dir);
    defer config.deinit(allocator);

    try site.generate(allocator, base_dir, .{
        .out_dir_path = config.dist_dir,
        .posts_dir_path = config.posts_dir,
        .static_dir_path = config.static_dir,
        .site_title = config.title,
        .site_description = config.description,
        .base_url = config.base_url,
        .log_warnings = log_warnings,
    });
}

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
        var config = try loadSiteConfig(allocator, base_dir);
        defer config.deinit(allocator);
        try site.generate(allocator, base_dir, .{
            .out_dir_path = config.dist_dir,
            .posts_dir_path = config.posts_dir,
            .static_dir_path = config.static_dir,
            .site_title = config.title,
            .site_description = config.description,
            .base_url = config.base_url,
        });
        try stdout.print("Generated site in {s}/\n", .{config.dist_dir});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 8080;
        var watch_enabled = true;
        var poll_ms: u64 = 500;
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

        var config = try loadSiteConfig(allocator, base_dir);
        defer config.deinit(allocator);

        try site.generate(allocator, base_dir, .{
            .out_dir_path = config.dist_dir,
            .posts_dir_path = config.posts_dir,
            .static_dir_path = config.static_dir,
            .site_title = config.title,
            .site_description = config.description,
            .base_url = config.base_url,
        });
        try stdout.print("Serving {s}/ at http://{s}:{d}/\n", .{ config.dist_dir, host, port });
        if (watch_enabled) {
            const max_poll_ms: u64 = 60_000;
            if (poll_ms > max_poll_ms) {
                try stderr.print("error: --poll-ms must be <= {d}\n\n", .{max_poll_ms});
                try printUsage(stderr);
                return 2;
            }

            const poll_ns = std.math.mul(u64, poll_ms, std.time.ns_per_ms) catch {
                try stderr.writeAll("error: --poll-ms is too large\n\n");
                try printUsage(stderr);
                return 2;
            };

            var watcher_started = false;
            if (base_dir.openDir(".", .{ .iterate = true })) |dir| {
                var watch_dir = dir;
                defer watch_dir.close();

                if (watch.fingerprint(allocator, watch_dir, .{})) |_| {
                    const thread_args: WatchThreadArgs = .{
                        .base_dir = base_dir,
                        .poll_interval_ns = poll_ns,
                        .targets = .{},
                    };
                    if (std.Thread.spawn(.{}, watchThreadMain, .{thread_args})) |thread| {
                        thread.detach();
                        watcher_started = true;
                    } else |err| {
                        try stderr.print("warning: watcher disabled ({s})\n", .{@errorName(err)});
                    }
                } else |err| {
                    try stderr.print("warning: watcher disabled ({s})\n", .{@errorName(err)});
                }
            } else |err| {
                try stderr.print("warning: watcher disabled ({s})\n", .{@errorName(err)});
            }

            if (watcher_started) try stdout.print("Watching for changes (polling every {d}ms)\n", .{poll_ms});
        }
        try server.serve(base_dir, .{ .host = host, .port = port, .out_dir_path = config.dist_dir });
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
        \\  blog serve [--host 127.0.0.1] [--port 8080] [--no-watch] [--poll-ms 500]
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

    var stable = watch.fingerprint(allocator, base_dir, args.targets) catch |err| {
        std.log.err("watch: initial fingerprint failed: {s}", .{@errorName(err)});
        return;
    };

    var pending: ?u64 = null;
    while (true) {
        std.Thread.sleep(args.poll_interval_ns);

        const current = watch.fingerprint(allocator, base_dir, args.targets) catch |err| {
            std.log.err("watch: fingerprint failed: {s}", .{@errorName(err)});
            continue;
        };
        if (current == stable) {
            pending = null;
            continue;
        }
        if (pending == null or pending.? != current) {
            pending = current;
            continue;
        }
        stable = current;
        pending = null;

        std.log.info("Change detected; rebuilding...", .{});
        generateFromConfig(allocator, base_dir, true) catch |err| {
            std.log.err("Rebuild failed: {s}", .{@errorName(err)});
            continue;
        };
        std.log.info("Rebuild complete.", .{});
    }
}

fn stripInlineComment(value: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, value, " \t");
    if (trimmed.len == 0) return trimmed;

    if (trimmed[0] == '"' or trimmed[0] == '\'') {
        const quote = trimmed[0];
        const end_quote = findClosingQuote(trimmed, quote) orelse return trimmed;
        const after = std.mem.trimLeft(u8, trimmed[end_quote + 1 ..], " \t");
        if (after.len == 0 or after[0] == '#') return trimmed[0 .. end_quote + 1];
        return trimmed;
    }

    const hash = std.mem.indexOfScalar(u8, trimmed, '#') orelse return trimmed;
    if (hash == 0) return "";
    if (!std.ascii.isWhitespace(trimmed[hash - 1])) return trimmed;
    return std.mem.trimRight(u8, trimmed[0..hash], " \t");
}

fn findClosingQuote(value: []const u8, quote: u8) ?usize {
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        if (value[i] != quote) continue;
        if (i > 0 and value[i - 1] == '\\') continue;
        return i;
    }
    return null;
}

fn parseScalar(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
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
