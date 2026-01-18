const std = @import("std");

const site = @import("site.zig");
const server = @import("server.zig");
const watch = @import("watch.zig");
const scalars = @import("scalars.zig");
const linkedin = @import("linkedin.zig");

const site_config_path: []const u8 = "site.yml";

const SiteConfig = struct {
    raw: ?[]u8 = null,

    title: []const u8 = "Blog",
    description: []const u8 = "",
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
        value = scalars.stripInlineComment(value);
        const scalar = scalars.parseScalar(value);
        if (scalar.len == 0) continue;

        if (std.mem.eql(u8, key, "title")) config.title = scalar;
        if (std.mem.eql(u8, key, "description")) config.description = scalar;
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

fn watchTargetsFromConfig(config: SiteConfig) watch.WatchTargets {
    return .{
        .posts_dir_path = config.posts_dir,
        .static_dir_path = config.static_dir,
        .site_config_path = site_config_path,
    };
}

fn fingerprintFromConfig(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !u64 {
    var config = try loadSiteConfig(allocator, base_dir);
    defer config.deinit(allocator);
    return watch.fingerprint(allocator, base_dir, watchTargetsFromConfig(config));
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

                if (fingerprintFromConfig(allocator, watch_dir)) |_| {
                    const thread_args: WatchThreadArgs = .{
                        .base_dir = base_dir,
                        .poll_interval_ns = poll_ns,
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

    if (std.mem.eql(u8, cmd, "linkedin")) {
        return runLinkedIn(allocator, base_dir, args[2..], stdout, stderr);
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
        \\  blog linkedin [--file posts/post.md] [--changed <git-ref>] [--dry-run]
        \\  blog linkedin auth
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
};

fn watchThreadMain(args: WatchThreadArgs) void {
    const allocator = std.heap.c_allocator;

    var base_dir = args.base_dir.openDir(".", .{ .iterate = true }) catch |err| {
        std.log.err("watch: open base dir failed: {s}", .{@errorName(err)});
        return;
    };
    defer base_dir.close();

    var stable = fingerprintFromConfig(allocator, base_dir) catch |err| {
        std.log.err("watch: initial fingerprint failed: {s}", .{@errorName(err)});
        return;
    };

    var pending: ?u64 = null;
    while (true) {
        std.Thread.sleep(args.poll_interval_ns);

        const current = fingerprintFromConfig(allocator, base_dir) catch |err| {
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

const max_linkedin_chars: usize = 3000;
const max_linkedin_hashtags: usize = 3;
const linkedin_scope = "r_liteprofile w_member_social";
const dotenv_path: []const u8 = ".env";
const default_redirect_uri = "http://127.0.0.1:8123/linkedin/callback";

fn runLinkedIn(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    var changed_ref: ?[]const u8 = null;
    var dry_run = false;
    var whoami = false;
    var auth = false;

    var idx: usize = 0;
    if (idx < args.len and std.mem.eql(u8, args[idx], "auth")) {
        auth = true;
        idx += 1;
    }
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--file")) {
            idx += 1;
            if (idx >= args.len) {
                try stderr.writeAll("error: --file requires a value\n\n");
                try printLinkedInUsage(stderr);
                return 2;
            }
            try files.append(allocator, args[idx]);
        } else if (std.mem.eql(u8, arg, "--changed")) {
            idx += 1;
            if (idx >= args.len) {
                try stderr.writeAll("error: --changed requires a value\n\n");
                try printLinkedInUsage(stderr);
                return 2;
            }
            if (changed_ref != null) {
                try stderr.writeAll("error: --changed specified more than once\n\n");
                try printLinkedInUsage(stderr);
                return 2;
            }
            changed_ref = args[idx];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--whoami")) {
            whoami = true;
        } else if (std.mem.eql(u8, arg, "--auth")) {
            auth = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try printLinkedInUsage(stdout);
            return 0;
        } else {
            try stderr.print("error: unknown argument '{s}'\n\n", .{arg});
            try printLinkedInUsage(stderr);
            return 2;
        }
    }

    if (files.items.len != 0 and changed_ref != null) {
        try stderr.writeAll("error: use --file or --changed, not both\n\n");
        try printLinkedInUsage(stderr);
        return 2;
    }

    if (whoami and (files.items.len != 0 or changed_ref != null or dry_run or auth)) {
        try stderr.writeAll("error: --whoami cannot be combined with other options\n\n");
        try printLinkedInUsage(stderr);
        return 2;
    }

    if (auth and (files.items.len != 0 or changed_ref != null or dry_run)) {
        try stderr.writeAll("error: auth cannot be combined with posting options\n\n");
        try printLinkedInUsage(stderr);
        return 2;
    }

    var dot_env = try DotEnv.load(allocator, base_dir, dotenv_path);
    defer dot_env.deinit(allocator);

    if (auth) {
        return runLinkedInAuth(allocator, base_dir, stdout, stderr, &dot_env);
    }

    if (whoami) {
        const access_token = (try getEnvRequired(allocator, stderr, &dot_env, "LINKEDIN_ACCESS_TOKEN")) orelse return 2;
        defer allocator.free(access_token);

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var result = try linkedin.fetchPersonId(allocator, &client, access_token);
        defer result.deinit(allocator);

        if (result.status.class() != .success) {
            try stderr.print("error: LinkedIn whoami failed (HTTP {d})\n{s}\n", .{
                @intFromEnum(result.status),
                result.body,
            });
            return 1;
        }

        const person_id = result.person_id orelse {
            try stderr.writeAll("error: LinkedIn whoami returned no id\n");
            return 1;
        };

        const author_urn = try std.fmt.allocPrint(allocator, "urn:li:person:{s}", .{person_id});
        defer allocator.free(author_urn);

        try stdout.print("export LINKEDIN_PERSON_ID={s}\nexport LINKEDIN_AUTHOR_URN={s}\n", .{
            person_id,
            author_urn,
        });
        return 0;
    }

    var config = try loadSiteConfig(allocator, base_dir);
    defer config.deinit(allocator);

    var posts: std.ArrayList(linkedin.Post) = .empty;
    defer {
        for (posts.items) |*post| post.deinit(allocator);
        posts.deinit(allocator);
    }

    if (files.items.len != 0) {
        for (files.items) |path| {
            const maybe_post = try linkedin.loadPost(allocator, base_dir, path, config.base_url);
            if (maybe_post == null) {
                try stdout.print("Skipping draft: {s}\n", .{path});
                continue;
            }
            try posts.append(allocator, maybe_post.?);
        }
    } else if (changed_ref) |ref| {
        var changed = try gitChangedPostPaths(allocator, base_dir, config.posts_dir, ref);
        defer freeStringList(&changed, allocator);

        if (changed.items.len == 0) {
            try stdout.writeAll("No changed posts to share.\n");
            return 0;
        }

        for (changed.items) |path| {
            const maybe_post = try linkedin.loadPost(allocator, base_dir, path, config.base_url);
            if (maybe_post == null) {
                try stdout.print("Skipping draft: {s}\n", .{path});
                continue;
            }
            try posts.append(allocator, maybe_post.?);
        }
    } else {
        const latest = try linkedin.findLatestPost(allocator, base_dir, config.posts_dir, config.base_url);
        if (latest == null) {
            try stdout.writeAll("No posts found to share.\n");
            return 0;
        }
        try posts.append(allocator, latest.?);
    }

    if (posts.items.len == 0) {
        try stdout.writeAll("No eligible posts to share.\n");
        return 0;
    }

    if (dry_run) {
        for (posts.items) |post| {
            const share_text = try linkedin.composeShareText(allocator, &post, max_linkedin_chars, max_linkedin_hashtags);
            defer allocator.free(share_text);
            try stdout.print("LinkedIn dry-run: {s}\n{s}\n\n", .{ post.parsed.front_matter.title, share_text });
        }
        return 0;
    }

    const access_token = (try getEnvRequired(allocator, stderr, &dot_env, "LINKEDIN_ACCESS_TOKEN")) orelse return 2;
    defer allocator.free(access_token);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const author_urn = (try resolveAuthorUrn(allocator, stderr, &dot_env, &client, access_token)) orelse return 2;
    defer allocator.free(author_urn);

    for (posts.items) |post| {
        const share_text = try linkedin.composeShareText(allocator, &post, max_linkedin_chars, max_linkedin_hashtags);
        defer allocator.free(share_text);

        var result = try linkedin.postToLinkedIn(
            allocator,
            &client,
            access_token,
            author_urn,
            share_text,
            post.parsed.front_matter.title,
            post.parsed.front_matter.description,
            post.url,
        );
        defer result.deinit(allocator);

        if (result.status.class() != .success) {
            try stderr.print(
                "error: LinkedIn post failed for {s} (HTTP {d})\n{s}\n",
                .{ post.parsed.front_matter.title, @intFromEnum(result.status), result.body },
            );
            return 1;
        }

        try stdout.print("LinkedIn: posted {s}\n", .{post.parsed.front_matter.title});
    }

    return 0;
}

fn printLinkedInUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  blog linkedin [--file posts/post.md] [--changed <git-ref>] [--dry-run]
        \\  blog linkedin --whoami
        \\  blog linkedin auth
        \\  blog linkedin --auth
        \\
        \\Examples:
        \\  blog linkedin --file posts/hello-world.md
        \\  blog linkedin --changed HEAD~1
        \\  blog linkedin --dry-run
        \\  blog linkedin --whoami
        \\  blog linkedin auth
        \\
    );
}

const EnvLine = union(enum) {
    raw: []u8,
    pair: struct { key: []u8, value: []u8 },
};

const DotEnv = struct {
    lines: std.ArrayList(EnvLine),
    path: []const u8,

    pub fn load(allocator: std.mem.Allocator, base_dir: std.fs.Dir, path: []const u8) !DotEnv {
        var lines: std.ArrayList(EnvLine) = .empty;

        const raw = base_dir.readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return .{ .lines = lines, .path = path },
            else => return err,
        };
        defer allocator.free(raw);

        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            try lines.append(allocator, try parseEnvLine(allocator, trimmed));
        }

        return .{ .lines = lines, .path = path };
    }

    pub fn deinit(self: *DotEnv, allocator: std.mem.Allocator) void {
        for (self.lines.items) |*line| {
            switch (line.*) {
                .raw => |raw| allocator.free(raw),
                .pair => |pair| {
                    allocator.free(pair.key);
                    allocator.free(pair.value);
                },
            }
        }
        self.lines.deinit(allocator);
        self.* = undefined;
    }

    pub fn getOwned(self: *DotEnv, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        for (self.lines.items) |line| {
            switch (line) {
                .pair => |pair| if (std.mem.eql(u8, pair.key, key)) {
                    return try allocator.dupe(u8, pair.value);
                },
                else => {},
            }
        }
        return null;
    }

    pub fn set(self: *DotEnv, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.lines.items) |*line| {
            switch (line.*) {
                .pair => |pair| if (std.mem.eql(u8, pair.key, key)) {
                    allocator.free(pair.value);
                    line.* = .{ .pair = .{
                        .key = pair.key,
                        .value = try allocator.dupe(u8, value),
                    } };
                    return;
                },
                else => {},
            }
        }

        try self.lines.append(allocator, .{ .pair = .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        } });
    }

    pub fn write(self: *DotEnv, allocator: std.mem.Allocator, base_dir: std.fs.Dir) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        for (self.lines.items) |line| {
            switch (line) {
                .raw => |raw| try out.appendSlice(allocator, raw),
                .pair => |pair| {
                    try out.appendSlice(allocator, pair.key);
                    try out.append(allocator, '=');
                    try appendEnvValue(&out, allocator, pair.value);
                },
            }
            try out.append(allocator, '\n');
        }

        try base_dir.writeFile(.{ .sub_path = self.path, .data = out.items });
    }
};

fn getEnvRequired(
    allocator: std.mem.Allocator,
    stderr: anytype,
    dot_env: *DotEnv,
    name: []const u8,
) !?[]u8 {
    if (try getEnvOptional(allocator, dot_env, name)) |val| return val;
    try stderr.print("error: {s} is required\n", .{name});
    return null;
}

fn getEnvOptional(allocator: std.mem.Allocator, dot_env: *DotEnv, name: []const u8) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, name)) |val| {
        return val;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    if (try dot_env.getOwned(allocator, name)) |val| return val;
    return null;
}

fn resolveAuthorUrn(
    allocator: std.mem.Allocator,
    stderr: anytype,
    dot_env: *DotEnv,
    client: *std.http.Client,
    access_token: []const u8,
) !?[]u8 {
    var author_urn = try getEnvOptional(allocator, dot_env, "LINKEDIN_AUTHOR_URN");
    if (author_urn) |urn| {
        if (urn.len != 0) return urn;
        allocator.free(urn);
        author_urn = null;
    }

    const person_id = try getEnvOptional(allocator, dot_env, "LINKEDIN_PERSON_ID");
    defer if (person_id) |pid| allocator.free(pid);
    if (person_id) |pid| {
        if (pid.len == 0) {
            try stderr.writeAll("error: LINKEDIN_PERSON_ID is empty\n");
            return null;
        }
        return try std.fmt.allocPrint(allocator, "urn:li:person:{s}", .{pid});
    }

    var result = try linkedin.fetchPersonId(allocator, client, access_token);
    defer result.deinit(allocator);

    if (result.status.class() != .success) {
        try stderr.print("error: LinkedIn profile lookup failed (HTTP {d})\n{s}\n", .{
            @intFromEnum(result.status),
            result.body,
        });
        return null;
    }

    const fetched_id = result.person_id orelse {
        try stderr.writeAll("error: LinkedIn profile lookup returned no id\n");
        return null;
    };

    return try std.fmt.allocPrint(allocator, "urn:li:person:{s}", .{fetched_id});
}

fn runLinkedInAuth(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    stdout: anytype,
    stderr: anytype,
    dot_env: *DotEnv,
) !u8 {
    const client_id = try getEnvOrPrompt(
        allocator,
        stdout,
        dot_env,
        "LINKEDIN_CLIENT_ID",
        "LinkedIn Client ID: ",
        null,
    );
    defer allocator.free(client_id);

    const client_secret = try getEnvOrPrompt(
        allocator,
        stdout,
        dot_env,
        "LINKEDIN_CLIENT_SECRET",
        "LinkedIn Client Secret (input will be visible): ",
        null,
    );
    defer allocator.free(client_secret);

    const redirect_uri = try getEnvOrPrompt(
        allocator,
        stdout,
        dot_env,
        "LINKEDIN_REDIRECT_URI",
        "Redirect URI",
        default_redirect_uri,
    );
    defer allocator.free(redirect_uri);

    var redirect = try parseRedirectUri(allocator, redirect_uri);
    defer redirect.deinit(allocator);

    const state = try randomStateHex(allocator, 16);
    defer allocator.free(state);

    const auth_url = try linkedin.buildAuthUrl(
        allocator,
        client_id,
        redirect_uri,
        state,
        linkedin_scope,
    );
    defer allocator.free(auth_url);

    try stdout.print("Make sure this redirect URI is registered in your LinkedIn app:\n  {s}\n\n", .{redirect_uri});
    try stdout.writeAll("Open this URL to authorize:\n");
    try stdout.print("{s}\n\n", .{auth_url});
    try stdout.print("Listening on {s}:{d} ...\n", .{ redirect.listen_host, redirect.port });

    var listener = try std.net.Address.parseIp(redirect.listen_host, redirect.port);
    var tcp_server = try listener.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    openUrlInBrowser(allocator, auth_url) catch {};

    const code = waitForOAuthCode(allocator, &tcp_server, redirect.path, state, stdout, stderr) catch |err| {
        try stderr.print("error: OAuth redirect failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(code);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var token = try linkedin.exchangeAuthCode(
        allocator,
        &client,
        client_id,
        client_secret,
        redirect_uri,
        code,
    );
    defer token.deinit(allocator);

    if (token.status.class() != .success or token.access_token == null) {
        try stderr.print("error: LinkedIn token exchange failed (HTTP {d})\n{s}\n", .{
            @intFromEnum(token.status),
            token.body,
        });
        return 1;
    }

    const access_token = token.access_token.?;

    try dot_env.set(allocator, "LINKEDIN_CLIENT_ID", client_id);
    try dot_env.set(allocator, "LINKEDIN_CLIENT_SECRET", client_secret);
    try dot_env.set(allocator, "LINKEDIN_REDIRECT_URI", redirect_uri);
    try dot_env.set(allocator, "LINKEDIN_ACCESS_TOKEN", access_token);

    if (token.expires_in) |expires_in| {
        const expires_in_str = try std.fmt.allocPrint(allocator, "{d}", .{expires_in});
        defer allocator.free(expires_in_str);
        try dot_env.set(allocator, "LINKEDIN_ACCESS_TOKEN_EXPIRES_IN", expires_in_str);

        const expires_at = std.time.timestamp() + expires_in;
        const expires_at_str = try std.fmt.allocPrint(allocator, "{d}", .{expires_at});
        defer allocator.free(expires_at_str);
        try dot_env.set(allocator, "LINKEDIN_ACCESS_TOKEN_EXPIRES_AT", expires_at_str);
    }

    var me = try linkedin.fetchPersonId(allocator, &client, access_token);
    defer me.deinit(allocator);

    if (me.status.class() == .success) {
        if (me.person_id) |pid| {
            const author_urn = try std.fmt.allocPrint(allocator, "urn:li:person:{s}", .{pid});
            defer allocator.free(author_urn);
            try dot_env.set(allocator, "LINKEDIN_PERSON_ID", pid);
            try dot_env.set(allocator, "LINKEDIN_AUTHOR_URN", author_urn);
        }
    } else {
        try stderr.print("warning: LinkedIn profile lookup failed (HTTP {d})\n{s}\n", .{
            @intFromEnum(me.status),
            me.body,
        });
    }

    try dot_env.write(allocator, base_dir);

    try stdout.print("Saved LinkedIn credentials to {s}.\n", .{dotenv_path});
    try stdout.writeAll("You can now post with:\n  zig build run -- linkedin --file posts/your-post.md\n");
    return 0;
}

const RedirectTarget = struct {
    listen_host: []u8,
    port: u16,
    path: []u8,

    pub fn deinit(self: *RedirectTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.listen_host);
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn parseRedirectUri(allocator: std.mem.Allocator, redirect_uri: []const u8) !RedirectTarget {
    const uri = std.Uri.parse(redirect_uri) catch return error.InvalidRedirectUri;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidRedirectUriScheme;

    var host_buf: [std.Uri.host_name_max]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return error.InvalidRedirectUriHost;
    if (host.len == 0) return error.InvalidRedirectUriHost;

    var listen_host = host;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        listen_host = "127.0.0.1";
    }

    const port = uri.port orelse 80;
    if (port == 0) return error.InvalidRedirectUriPort;

    var path_buf: [1024]u8 = undefined;
    const path_raw = uri.path.toRaw(&path_buf) catch return error.RedirectUriPathTooLong;
    const path = if (path_raw.len == 0) "/" else path_raw;

    return .{
        .listen_host = try allocator.dupe(u8, listen_host),
        .port = port,
        .path = try allocator.dupe(u8, path),
    };
}

fn waitForOAuthCode(
    allocator: std.mem.Allocator,
    tcp_server: *std.net.Server,
    expected_path: []const u8,
    expected_state: []const u8,
    stdout: anytype,
    stderr: anytype,
) ![]u8 {
    const connection = try tcp_server.accept();
    defer connection.stream.close();

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = connection.stream.reader(&recv_buffer);
    var connection_writer = connection.stream.writer(&send_buffer);
    var http_server: std.http.Server = .init(connection_reader.interface(), &connection_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return error.OAuthConnectionClosed,
        else => return err,
    };

    const target = request.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = if (query_start == 0) "/" else target[0..query_start];
    if (!std.mem.eql(u8, path, expected_path)) {
        try respondOAuth(&request, .bad_request, "Unexpected redirect path.");
        return error.UnexpectedRedirectPath;
    }

    const query = if (query_start < target.len) target[query_start + 1 ..] else "";

    if (try queryParamDecoded(allocator, query, "error")) |err_val| {
        defer allocator.free(err_val);
        const desc = try queryParamDecoded(allocator, query, "error_description");
        defer if (desc) |d| allocator.free(d);
        try respondOAuth(&request, .bad_request, "Authorization failed. You can close this window.");
        try stderr.print("error: LinkedIn authorization error: {s}\n", .{err_val});
        if (desc) |d| try stderr.print("error: {s}\n", .{d});
        return error.OAuthDenied;
    }

    const code = try queryParamDecoded(allocator, query, "code") orelse {
        try respondOAuth(&request, .bad_request, "Missing code. You can close this window.");
        return error.MissingAuthCode;
    };
    errdefer allocator.free(code);

    const state = try queryParamDecoded(allocator, query, "state") orelse {
        try respondOAuth(&request, .bad_request, "Missing state. You can close this window.");
        return error.MissingAuthState;
    };
    defer allocator.free(state);

    if (!std.mem.eql(u8, state, expected_state)) {
        try respondOAuth(&request, .bad_request, "State mismatch. You can close this window.");
        return error.AuthStateMismatch;
    }

    try respondOAuth(&request, .ok, "Authorization complete. You can close this window.");
    try stdout.writeAll("Authorization complete.\n");
    return code;
}

fn respondOAuth(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    };
    try request.respond(message, .{
        .status = status,
        .extra_headers = &headers,
    });
}

fn queryParamDecoded(allocator: std.mem.Allocator, query: []const u8, key: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        if (!std.mem.eql(u8, raw_key, key)) continue;
        const raw_val = if (eq < pair.len) pair[eq + 1 ..] else "";
        return try percentDecodeAlloc(allocator, raw_val);
    }
    return null;
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            continue;
        }
        if (c != '%' or i + 2 >= input.len) {
            try out.append(allocator, c);
            continue;
        }
        const hi = try parseHexNibble(input[i + 1]);
        const lo = try parseHexNibble(input[i + 2]);
        try out.append(allocator, (hi << 4) | lo);
        i += 2;
    }

    return out.toOwnedSlice(allocator);
}

fn parseHexNibble(c: u8) !u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
    return error.InvalidHexDigit;
}

fn randomStateHex(allocator: std.mem.Allocator, bytes_len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, bytes_len);
    defer allocator.free(bytes);

    std.crypto.random.bytes(bytes);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const hex = "0123456789ABCDEF";
    for (bytes) |b| {
        try out.append(allocator, hex[b >> 4]);
        try out.append(allocator, hex[b & 0x0F]);
    }

    return out.toOwnedSlice(allocator);
}

fn getEnvOrPrompt(
    allocator: std.mem.Allocator,
    stdout: anytype,
    dot_env: *DotEnv,
    key: []const u8,
    prompt: []const u8,
    default_value: ?[]const u8,
) ![]u8 {
    if (try getEnvOptional(allocator, dot_env, key)) |value| {
        if (value.len != 0) return value;
        allocator.free(value);
    }

    while (true) {
        const line = try promptLine(allocator, stdout, prompt, default_value);
        if (line.len == 0) {
            if (default_value) |d| {
                allocator.free(line);
                return try allocator.dupe(u8, d);
            }
            allocator.free(line);
            continue;
        }
        return line;
    }
}

fn promptLine(
    allocator: std.mem.Allocator,
    stdout: anytype,
    prompt: []const u8,
    default_value: ?[]const u8,
) ![]u8 {
    if (default_value) |d| {
        try stdout.print("{s} [{s}]: ", .{ prompt, d });
    } else {
        try stdout.print("{s}", .{prompt});
    }

    const stdin_reader = std.fs.File.stdin().deprecatedReader();
    const raw = try stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096) orelse return error.EndOfStream;
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.ptr != raw.ptr or trimmed.len != raw.len) {
        const owned = try allocator.dupe(u8, trimmed);
        allocator.free(raw);
        return owned;
    }
    return raw;
}

fn openUrlInBrowser(allocator: std.mem.Allocator, url: []const u8) !void {
    const builtin = @import("builtin");
    const argv = switch (builtin.os.tag) {
        .macos => &[_][]const u8{ "open", url },
        .linux => &[_][]const u8{ "xdg-open", url },
        .windows => &[_][]const u8{ "cmd", "/c", "start", url },
        else => &[_][]const u8{ "xdg-open", url },
    };

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 0,
    }) catch {};
}

fn parseEnvLine(allocator: std.mem.Allocator, raw_line: []const u8) !EnvLine {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') {
        return .{ .raw = try allocator.dupe(u8, raw_line) };
    }

    var line = trimmed;
    if (std.mem.startsWith(u8, line, "export ")) {
        line = std.mem.trimLeft(u8, line["export ".len..], " \t");
    }

    const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
        return .{ .raw = try allocator.dupe(u8, raw_line) };
    };

    const key = std.mem.trim(u8, line[0..eq], " \t");
    if (key.len == 0) {
        return .{ .raw = try allocator.dupe(u8, raw_line) };
    }

    const value_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const value = try allocator.dupe(u8, parseEnvValue(value_raw));

    return .{ .pair = .{
        .key = try allocator.dupe(u8, key),
        .value = value,
    } };
}

fn parseEnvValue(raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;
    if ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\'')) {
        return raw[1 .. raw.len - 1];
    }
    const hash = std.mem.indexOfScalar(u8, raw, '#') orelse return raw;
    if (hash == 0) return raw;
    if (std.mem.indexOfScalar(u8, raw[0..hash], ' ') != null or std.mem.indexOfScalar(u8, raw[0..hash], '\t') != null) {
        return std.mem.trimRight(u8, raw[0..hash], " \t");
    }
    return raw;
}

fn appendEnvValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (!needsEnvQuote(value)) {
        try out.appendSlice(allocator, value);
        return;
    }

    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn needsEnvQuote(value: []const u8) bool {
    for (value) |c| {
        if (c == ' ' or c == '\t' or c == '#' or c == '"' or c == '\'') return true;
    }
    return false;
}

fn gitChangedPostPaths(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    posts_dir: []const u8,
    from_ref: []const u8,
) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;

    if (isZeroOid(from_ref)) return list;

    const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{from_ref});
    defer allocator.free(range);

    const argv = [_][]const u8{
        "git",
        "diff",
        "--name-only",
        "--diff-filter=ACMRT",
        range,
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .cwd_dir = base_dir,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            return error.GitDiffFailed;
        },
        else => return error.GitDiffFailed,
    }

    const posts_root = std.mem.trimRight(u8, posts_dir, "/");
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{posts_root});
    defer allocator.free(prefix);

    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        if (!std.mem.endsWith(u8, trimmed, ".md")) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return list;
}

fn freeStringList(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
    list.* = .empty;
}

fn isZeroOid(oid: []const u8) bool {
    if (oid.len != 40) return false;
    for (oid) |c| {
        if (c != '0') return false;
    }
    return true;
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
