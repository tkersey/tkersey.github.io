const std = @import("std");

const max_content_hash_bytes: u64 = 64 * 1024;
const max_symlink_target_bytes: usize = 4096;

pub const WatchTargets = struct {
    posts_dir_path: []const u8 = "posts",
    static_dir_path: []const u8 = "static",
    templates_dir_path: []const u8 = "templates",
    site_config_path: []const u8 = "site.yml",
};

pub fn fingerprint(allocator: std.mem.Allocator, io: std.Io, base_dir: std.Io.Dir, targets: WatchTargets) !u64 {
    var acc: FingerprintAcc = .{};

    const base_abs = try base_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base_abs);

    try addDirTreeFingerprint(allocator, io, base_dir, base_abs, targets.posts_dir_path, &acc);
    try addDirTreeFingerprint(allocator, io, base_dir, base_abs, targets.static_dir_path, &acc);
    try addDirTreeFingerprint(allocator, io, base_dir, base_abs, targets.templates_dir_path, &acc);
    try addFileFingerprint(io, base_dir, targets.site_config_path, &acc);

    return acc.final();
}

const FingerprintAcc = struct {
    xor: u64 = 0,
    sum: u64 = 0,
    count: u64 = 0,

    fn add(self: *FingerprintAcc, h: u64) void {
        self.xor ^= h;
        self.sum +%= h *% 0x9e3779b97f4a7c15;
        self.count +%= 1;
    }

    fn final(self: FingerprintAcc) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.xor));
        h.update(std.mem.asBytes(&self.sum));
        h.update(std.mem.asBytes(&self.count));
        return h.final();
    }
};

fn addFileFingerprint(io: std.Io, base_dir: std.Io.Dir, path: []const u8, acc: *FingerprintAcc) !void {
    const stat = base_dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            acc.add(hashSentinel(path, .missing_file));
            return;
        },
        else => return err,
    };

    if (stat.kind == .directory) {
        acc.add(hashSentinel(path, .unexpected_dir));
        return;
    }

    const content_hash = if (stat.kind == .file and stat.size <= max_content_hash_bytes)
        try hashFileContent(io, base_dir, path, max_content_hash_bytes)
    else
        null;

    acc.add(hashFile(path, stat, content_hash));
}

fn addDirTreeFingerprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    base_abs: []const u8,
    dir_path: []const u8,
    acc: *FingerprintAcc,
) !void {
    try validateWatchTargetDirPath(dir_path);

    const dir_abs = base_dir.realPathFileAlloc(io, dir_path, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            acc.add(hashSentinel(dir_path, .missing_dir));
            return;
        },
        else => return err,
    };
    defer allocator.free(dir_abs);

    if (std.mem.eql(u8, dir_abs, base_abs)) return error.WatchTargetIsBaseDir;
    if (!pathContains(base_abs, dir_abs)) return error.WatchTargetEscapesBaseDir;

    var root = try base_dir.openDir(io, dir_path, .{ .iterate = true });
    defer root.close(io);

    acc.add(hashSentinel(dir_path, .present_dir));

    var stack: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stack.items) |p| allocator.free(p);
        stack.deinit(allocator);
    }

    const root_rel_path = try allocator.dupe(u8, "");
    stack.append(allocator, root_rel_path) catch |err| {
        allocator.free(root_rel_path);
        return err;
    };

    while (stack.pop()) |rel_path| {
        defer allocator.free(rel_path);

        var dir: std.Io.Dir = root;
        var close_dir = false;
        if (rel_path.len != 0) {
            dir = try root.openDir(io, rel_path, .{ .iterate = true });
            close_dir = true;
        }
        defer if (close_dir) dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            switch (entry.kind) {
                .file => {
                    const stat = try dir.statFile(io, entry.name, .{});
                    const content_hash = if (stat.size <= max_content_hash_bytes)
                        try hashFileContent(io, dir, entry.name, max_content_hash_bytes)
                    else
                        null;
                    acc.add(hashTreeFile(dir_path, rel_path, entry.name, stat, content_hash));
                },
                .sym_link => {
                    var buf: [max_symlink_target_bytes]u8 = undefined;
                    const target_len = dir.readLink(io, entry.name, &buf) catch null;
                    const target = if (target_len) |n| buf[0..n] else null;
                    acc.add(hashSymlinkEntry(dir_path, rel_path, entry.name, target));
                },
                else => acc.add(hashDirEntry(dir_path, rel_path, entry)),
            }

            if (entry.kind == .directory) {
                const child_rel_path = child_rel_path: {
                    if (rel_path.len == 0) break :child_rel_path try allocator.dupe(u8, entry.name);
                    break :child_rel_path try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ rel_path, std.fs.path.sep, entry.name });
                };
                stack.append(allocator, child_rel_path) catch |err| {
                    allocator.free(child_rel_path);
                    return err;
                };
            }
        }
    }
}

fn validateWatchTargetDirPath(path: []const u8) !void {
    const trimmed = trimTrailingSeps(std.mem.trim(u8, path, " \t"));
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return error.InvalidWatchTargetPath;
    if (std.fs.path.isAbsolute(trimmed)) return error.InvalidWatchTargetPath;
    if (std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidWatchTargetPath;
    if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) return error.InvalidWatchTargetPath;

    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.InvalidWatchTargetPath;
    }
}

fn pathContains(parent_path: []const u8, child_path: []const u8) bool {
    const parent = trimTrailingSeps(parent_path);
    const child = trimTrailingSeps(child_path);

    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return std.fs.path.isSep(child[parent.len]);
}

fn trimTrailingSeps(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

const SentinelKind = enum(u8) {
    missing_dir,
    present_dir,
    missing_file,
    unexpected_dir,
};

fn hashSentinel(path: []const u8, kind: SentinelKind) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update("sentinel");
    h.update(&.{0});
    h.update(path);
    const kind_byte: u8 = @intFromEnum(kind);
    h.update(std.mem.asBytes(&kind_byte));
    return h.final();
}

fn hashDirEntry(root_path: []const u8, rel_dir_path: []const u8, entry: std.Io.Dir.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update("entry");
    h.update(&.{0});
    h.update(root_path);
    h.update(&.{0});
    h.update(rel_dir_path);
    h.update(&.{0});
    h.update(entry.name);
    const kind_byte: u8 = @intFromEnum(entry.kind);
    h.update(std.mem.asBytes(&kind_byte));
    return h.final();
}

fn hashSymlinkEntry(root_path: []const u8, rel_dir_path: []const u8, name: []const u8, target: ?[]const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update("sym-link");
    h.update(&.{0});
    h.update(root_path);
    h.update(&.{0});
    h.update(rel_dir_path);
    h.update(&.{0});
    h.update(name);
    h.update(&.{0});
    if (target) |t| {
        h.update(t);
    } else {
        h.update("unreadable");
    }
    return h.final();
}

fn hashTreeFile(
    root_path: []const u8,
    rel_dir_path: []const u8,
    name: []const u8,
    stat: std.Io.File.Stat,
    content_hash: ?u64,
) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update("tree-file");
    h.update(&.{0});
    h.update(root_path);
    h.update(&.{0});
    h.update(rel_dir_path);
    h.update(&.{0});
    h.update(name);
    const kind_byte: u8 = @intFromEnum(stat.kind);
    h.update(std.mem.asBytes(&kind_byte));
    h.update(std.mem.asBytes(&stat.inode));
    h.update(std.mem.asBytes(&stat.size));
    h.update(std.mem.asBytes(&stat.mtime));
    h.update(std.mem.asBytes(&stat.ctime));
    if (content_hash) |ch| h.update(std.mem.asBytes(&ch));
    return h.final();
}

fn hashFile(path: []const u8, stat: std.Io.File.Stat, content_hash: ?u64) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update("file");
    h.update(&.{0});
    h.update(path);
    const kind_byte: u8 = @intFromEnum(stat.kind);
    h.update(std.mem.asBytes(&kind_byte));
    h.update(std.mem.asBytes(&stat.inode));
    h.update(std.mem.asBytes(&stat.size));
    h.update(std.mem.asBytes(&stat.mtime));
    h.update(std.mem.asBytes(&stat.ctime));
    if (content_hash) |ch| h.update(std.mem.asBytes(&ch));
    return h.final();
}

fn hashFileContent(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, max_bytes: u64) !u64 {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);

    var h = std.hash.Wyhash.init(0);
    h.update("content");
    h.update(&.{0});

    var buf: [8192]u8 = undefined;
    var reader_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    var remaining = max_bytes;
    while (remaining > 0) {
        const to_read: usize = @min(buf.len, @as(usize, @intCast(remaining)));
        const n = reader.interface.readSliceShort(buf[0..to_read]) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (n == 0) break;
        h.update(buf[0..n]);
        remaining -= n;
        if (n < to_read) break;
    }
    return h.final();
}

test "fingerprint changes when inputs change" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "posts");
    try tmp.dir.createDirPath(std.testing.io, "static");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site.yml", .data = "title: x\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "posts/a.md", .data =
        \\---
        \\title: A
        \\date: 2025-12-01
        \\---
        \\hi
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "static/style.css", .data = "a" });

    const a = try fingerprint(testing.allocator, std.testing.io, tmp.dir, .{});

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "posts/a.md", .data =
        \\---
        \\title: A
        \\date: 2025-12-01
        \\---
        \\hello
    });

    const b = try fingerprint(testing.allocator, std.testing.io, tmp.dir, .{});
    try testing.expect(a != b);
}

test "fingerprint changes when a watched directory appears" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const a = try fingerprint(testing.allocator, std.testing.io, tmp.dir, .{});
    try tmp.dir.createDirPath(std.testing.io, "templates");
    const b = try fingerprint(testing.allocator, std.testing.io, tmp.dir, .{});
    try testing.expect(a != b);
}

test "fingerprint changes when a symlink target changes" {
    const testing = std.testing;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "posts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "posts/a.md", .data = "a\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "posts/b.md", .data = "b\n" });

    try tmp.dir.symLink(std.testing.io, "a.md", "posts/link.md", .{ .is_directory = false });
    const a = try fingerprint(testing.allocator, std.testing.io, tmp.dir, .{});

    try tmp.dir.deleteFile(std.testing.io, "posts/link.md");
    try tmp.dir.symLink(std.testing.io, "b.md", "posts/link.md", .{ .is_directory = false });
    const b = try fingerprint(testing.allocator, std.testing.io, tmp.dir, .{});

    try testing.expect(a != b);
}

test "fingerprint rejects invalid watch target paths" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(
        error.InvalidWatchTargetPath,
        fingerprint(testing.allocator, std.testing.io, tmp.dir, .{ .posts_dir_path = ".." }),
    );
}

test "fingerprint rejects watch targets that escape the base dir" {
    const testing = std.testing;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(base_abs);

    const parent_abs = std.fs.path.dirname(base_abs) orelse return error.TestExpectedEqual;
    var parent_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, parent_abs, .{});
    defer parent_dir.close(std.testing.io);

    try parent_dir.createDirPath(std.testing.io, "outside-watch");
    defer parent_dir.deleteTree(std.testing.io, "outside-watch") catch {};
    try tmp.dir.symLink(std.testing.io, "../outside-watch", "posts", .{ .is_directory = true });

    try testing.expectError(
        error.WatchTargetEscapesBaseDir,
        fingerprint(testing.allocator, std.testing.io, tmp.dir, .{ .posts_dir_path = "posts" }),
    );
}
