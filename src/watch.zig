const std = @import("std");

pub const WatchTargets = struct {
    posts_dir_path: []const u8 = "posts",
    static_dir_path: []const u8 = "static",
    templates_dir_path: []const u8 = "templates",
    site_config_path: []const u8 = "site.yml",
};

pub fn fingerprint(allocator: std.mem.Allocator, base_dir: std.fs.Dir, targets: WatchTargets) !u64 {
    var acc: FingerprintAcc = .{};

    try addDirTreeFingerprint(allocator, base_dir, targets.posts_dir_path, &acc);
    try addDirTreeFingerprint(allocator, base_dir, targets.static_dir_path, &acc);
    try addDirTreeFingerprint(allocator, base_dir, targets.templates_dir_path, &acc);
    try addFileFingerprint(base_dir, targets.site_config_path, &acc);

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

fn addFileFingerprint(base_dir: std.fs.Dir, path: []const u8, acc: *FingerprintAcc) !void {
    const stat = base_dir.statFile(path) catch |err| switch (err) {
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

    acc.add(hashFile(path, stat));
}

fn addDirTreeFingerprint(allocator: std.mem.Allocator, base_dir: std.fs.Dir, dir_path: []const u8, acc: *FingerprintAcc) !void {
    var root = base_dir.openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            acc.add(hashSentinel(dir_path, .missing_dir));
            return;
        },
        else => return err,
    };
    defer root.close();

    acc.add(hashSentinel(dir_path, .present_dir));

    var stack: std.ArrayListUnmanaged([]u8) = .{};
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

        var dir: std.fs.Dir = root;
        var close_dir = false;
        if (rel_path.len != 0) {
            dir = try root.openDir(rel_path, .{ .iterate = true });
            close_dir = true;
        }
        defer if (close_dir) dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const stat = try dir.statFile(entry.name);
                    acc.add(hashTreeFile(dir_path, rel_path, entry.name, stat));
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

fn hashDirEntry(root_path: []const u8, rel_dir_path: []const u8, entry: std.fs.Dir.Entry) u64 {
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

fn hashTreeFile(root_path: []const u8, rel_dir_path: []const u8, name: []const u8, stat: std.fs.File.Stat) u64 {
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
    h.update(std.mem.asBytes(&stat.size));
    h.update(std.mem.asBytes(&stat.mtime));
    return h.final();
}

fn hashFile(path: []const u8, stat: std.fs.File.Stat) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update("file");
    h.update(&.{0});
    h.update(path);
    const kind_byte: u8 = @intFromEnum(stat.kind);
    h.update(std.mem.asBytes(&kind_byte));
    h.update(std.mem.asBytes(&stat.size));
    h.update(std.mem.asBytes(&stat.mtime));
    return h.final();
}

test "fingerprint changes when inputs change" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("posts");
    try tmp.dir.makePath("static");
    try tmp.dir.writeFile(.{ .sub_path = "site.yml", .data = "title: x\n" });
    try tmp.dir.writeFile(.{ .sub_path = "posts/a.md", .data = 
        \\---
        \\title: A
        \\date: 2025-12-01
        \\---
        \\hi
    });
    try tmp.dir.writeFile(.{ .sub_path = "static/style.css", .data = "a" });

    const a = try fingerprint(testing.allocator, tmp.dir, .{});

    try tmp.dir.writeFile(.{ .sub_path = "posts/a.md", .data = 
        \\---
        \\title: A
        \\date: 2025-12-01
        \\---
        \\hello
    });

    const b = try fingerprint(testing.allocator, tmp.dir, .{});
    try testing.expect(a != b);
}

test "fingerprint changes when a watched directory appears" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const a = try fingerprint(testing.allocator, tmp.dir, .{});
    try tmp.dir.makePath("templates");
    const b = try fingerprint(testing.allocator, tmp.dir, .{});
    try testing.expect(a != b);
}
