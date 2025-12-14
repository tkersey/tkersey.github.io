const std = @import("std");

const front_matter = @import("front_matter.zig");
const markdown_renderer = @import("markdown.zig");

pub const GenerateOptions = struct {
    out_dir_path: []const u8 = "dist",
    posts_dir_path: []const u8 = "posts",
    static_dir_path: []const u8 = "static",
    site_title: []const u8 = "Blog",
    site_description: []const u8 = "",
    base_url: []const u8 = "https://tkersey.github.io",
    log_warnings: bool = true,
};

const PostSummary = struct {
    title: []const u8,
    date: front_matter.Date,
    date_raw: []const u8,
    slug: []const u8,
    description: ?[]const u8,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.date_raw);
        alloc.free(self.slug);
        if (self.description) |d| alloc.free(d);
    }
};

pub fn generate(allocator: std.mem.Allocator, base_dir: std.fs.Dir, options: GenerateOptions) !void {
    try base_dir.makePath(options.out_dir_path);

    var out_dir = try base_dir.openDir(options.out_dir_path, .{ .iterate = true });
    defer out_dir.close();

    try validateStaticAndOutDirs(allocator, base_dir, options.out_dir_path, options.static_dir_path);

    try cleanDist(out_dir);

    try copyStaticAssets(allocator, base_dir, out_dir, options.static_dir_path);

    var posts_dir = base_dir.openDir(options.posts_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (posts_dir) |*d| d.close();

    var posts: std.ArrayListUnmanaged(PostSummary) = .{};
    defer {
        for (posts.items) |*post| post.deinit(allocator);
        posts.deinit(allocator);
    }

    if (posts_dir) |*pd| {
        var post_names: std.ArrayList([]const u8) = .empty;
        defer {
            for (post_names.items) |name| allocator.free(name);
            post_names.deinit(allocator);
        }

        var it = pd.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            try post_names.append(allocator, try allocator.dupe(u8, entry.name));
        }

        const SortContext = struct {
            pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        };
        std.mem.sortUnstable([]const u8, post_names.items, SortContext{}, SortContext.lessThan);

        var slug_owners: std.StringHashMapUnmanaged([]const u8) = .{};
        var slug_owner_keys: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (slug_owner_keys.items) |key| allocator.free(key);
            slug_owner_keys.deinit(allocator);
            slug_owners.deinit(allocator);
        }

        for (post_names.items) |md_name| {
            const stem = md_name[0 .. md_name.len - 3];

            const md = pd.readFileAlloc(allocator, md_name, 10 * 1024 * 1024) catch |err| {
                if (options.log_warnings) std.log.warn("posts/{s}: {s}", .{ md_name, @errorName(err) });
                return err;
            };

            var parsed = front_matter.parseOwnedBuffer(allocator, md) catch |err| {
                if (options.log_warnings) std.log.warn("posts/{s}: {s}", .{ md_name, @errorName(err) });
                return err;
            };
            defer parsed.deinit(allocator);
            if (parsed.front_matter.draft) continue;

            const base_slug_input = parsed.front_matter.slug orelse stem;
            const slug = try slugify(allocator, base_slug_input);
            if (slug_owners.get(slug)) |owner| {
                if (options.log_warnings) {
                    std.log.warn(
                        "duplicate slug '{s}' for posts/{s} (already used by posts/{s})",
                        .{ slug, md_name, owner },
                    );
                }
                allocator.free(slug);
                return error.DuplicateSlug;
            }
            const slug_key = try allocator.dupe(u8, slug);
            slug_owner_keys.append(allocator, slug_key) catch |err| {
                allocator.free(slug_key);
                return err;
            };
            try slug_owners.put(allocator, slug_key, md_name);

            const html_name = try std.fmt.allocPrint(allocator, "{s}.html", .{slug});
            defer allocator.free(html_name);

            generatePostPage(allocator, out_dir, html_name, parsed.front_matter.title, parsed.front_matter.date_raw, parsed.body) catch |err| {
                if (options.log_warnings) std.log.warn("posts/{s}: {s}", .{ md_name, @errorName(err) });
                return err;
            };

            try posts.append(allocator, .{
                .title = try allocator.dupe(u8, parsed.front_matter.title),
                .date = parsed.front_matter.date,
                .date_raw = try allocator.dupe(u8, parsed.front_matter.date_raw),
                .slug = slug,
                .description = if (parsed.front_matter.description) |desc|
                    try allocator.dupe(u8, desc)
                else
                    null,
            });
        }
    }

    const PostsSortContext = struct {
        pub fn lessThan(_: @This(), a: PostSummary, b: PostSummary) bool {
            if (a.date.year != b.date.year) return a.date.year > b.date.year;
            if (a.date.month != b.date.month) return a.date.month > b.date.month;
            if (a.date.day != b.date.day) return a.date.day > b.date.day;
            return std.mem.lessThan(u8, a.slug, b.slug);
        }
    };
    std.mem.sortUnstable(PostSummary, posts.items, PostsSortContext{}, PostsSortContext.lessThan);

    try generateFeedXml(out_dir, options, posts.items);

    var index_buf: [16 * 1024]u8 = undefined;
    var index_file = try out_dir.atomicFile("index.html", .{
        .write_buffer = &index_buf,
    });
    defer index_file.deinit();

    try writeDocumentStart(&index_file.file_writer.interface, options.site_title);
    try index_file.file_writer.interface.writeAll("<main>\n<h1>Posts</h1>\n<ul>\n");
    for (posts.items) |post| {
        try index_file.file_writer.interface.writeAll("<li><a href=\"");
        try writeEscapedHtml(&index_file.file_writer.interface, post.slug);
        try index_file.file_writer.interface.writeAll(".html\">");
        try writeEscapedHtml(&index_file.file_writer.interface, post.title);
        try index_file.file_writer.interface.writeAll("</a> <small><time datetime=\"");
        try writeEscapedHtml(&index_file.file_writer.interface, post.date_raw);
        try index_file.file_writer.interface.writeAll("\">");
        try writeEscapedHtml(&index_file.file_writer.interface, post.date_raw);
        try index_file.file_writer.interface.writeAll("</time></small></li>\n");
    }
    try index_file.file_writer.interface.writeAll("</ul>\n</main>\n");
    try writeDocumentEnd(&index_file.file_writer.interface);
    try index_file.finish();
}

fn generateFeedXml(out_dir: std.fs.Dir, options: GenerateOptions, posts: []const PostSummary) !void {
    var buf: [16 * 1024]u8 = undefined;
    var feed_file = try out_dir.atomicFile("feed.xml", .{ .write_buffer = &buf });
    defer feed_file.deinit();

    try feed_file.file_writer.interface.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try feed_file.file_writer.interface.writeAll("<rss version=\"2.0\">\n<channel>\n");

    try feed_file.file_writer.interface.writeAll("<title>");
    try writeEscapedXml(&feed_file.file_writer.interface, options.site_title);
    try feed_file.file_writer.interface.writeAll("</title>\n");

    try feed_file.file_writer.interface.writeAll("<link>");
    try writeEscapedXml(&feed_file.file_writer.interface, std.mem.trimRight(u8, options.base_url, "/"));
    try feed_file.file_writer.interface.writeAll("</link>\n");

    try feed_file.file_writer.interface.writeAll("<description>");
    try writeEscapedXml(&feed_file.file_writer.interface, options.site_description);
    try feed_file.file_writer.interface.writeAll("</description>\n");

    if (posts.len != 0) {
        try feed_file.file_writer.interface.writeAll("<lastBuildDate>");
        try writeRfc822Date(&feed_file.file_writer.interface, posts[0].date);
        try feed_file.file_writer.interface.writeAll("</lastBuildDate>\n");
    }

    try feed_file.file_writer.interface.writeAll("<generator>blog</generator>\n");

    for (posts) |post| {
        try feed_file.file_writer.interface.writeAll("<item>\n<title>");
        try writeEscapedXml(&feed_file.file_writer.interface, post.title);
        try feed_file.file_writer.interface.writeAll("</title>\n<link>");
        try writePostUrl(&feed_file.file_writer.interface, options.base_url, post.slug);
        try feed_file.file_writer.interface.writeAll("</link>\n<guid isPermaLink=\"true\">");
        try writePostUrl(&feed_file.file_writer.interface, options.base_url, post.slug);
        try feed_file.file_writer.interface.writeAll("</guid>\n<pubDate>");
        try writeRfc822Date(&feed_file.file_writer.interface, post.date);
        try feed_file.file_writer.interface.writeAll("</pubDate>\n");

        if (post.description) |desc| {
            try feed_file.file_writer.interface.writeAll("<description>");
            try writeEscapedXml(&feed_file.file_writer.interface, desc);
            try feed_file.file_writer.interface.writeAll("</description>\n");
        }

        try feed_file.file_writer.interface.writeAll("</item>\n");
    }

    try feed_file.file_writer.interface.writeAll("</channel>\n</rss>\n");
    try feed_file.finish();
}

fn writePostUrl(w: *std.Io.Writer, base_url: []const u8, slug: []const u8) !void {
    const base = std.mem.trimRight(u8, base_url, "/");
    try writeEscapedXml(w, base);
    try w.writeAll("/");
    try writeEscapedXml(w, slug);
    try w.writeAll(".html");
}

fn writeRfc822Date(w: *std.Io.Writer, date: front_matter.Date) !void {
    const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const wd: usize = weekdayForDate(date);
    const month = month_names[@intCast(date.month - 1)];

    var tmp: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &tmp,
        "{s}, {d:0>2} {s} {d} 00:00:00 GMT",
        .{ weekday_names[wd], date.day, month, date.year },
    );
    try w.writeAll(s);
}

fn weekdayForDate(date: front_matter.Date) usize {
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i32 = date.year;
    const m: i32 = date.month;
    const d: i32 = date.day;
    if (m < 3) y -= 1;
    const idx: usize = @intCast(m - 1);
    const dow: i32 = y + @divTrunc(y, @as(i32, 4)) - @divTrunc(y, @as(i32, 100)) + @divTrunc(y, @as(i32, 400)) + t[idx] + d;
    return @intCast(@mod(dow, @as(i32, 7)));
}

fn writeEscapedXml(w: *std.Io.Writer, input: []const u8) !void {
    var start: usize = 0;
    for (input, 0..) |c, i| {
        const escaped: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (escaped) |esc| {
            if (i > start) try w.writeAll(input[start..i]);
            try w.writeAll(esc);
            start = i + 1;
        }
    }
    if (start < input.len) try w.writeAll(input[start..]);
}

fn cleanDist(out_dir: std.fs.Dir) !void {
    var it = out_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
        switch (entry.kind) {
            .directory => try out_dir.deleteTree(entry.name),
            else => try out_dir.deleteFile(entry.name),
        }
    }
}

fn validateStaticAndOutDirs(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    out_dir_path: []const u8,
    static_dir_path: []const u8,
) !void {
    const out_abs = try base_dir.realpathAlloc(allocator, out_dir_path);
    defer allocator.free(out_abs);

    const static_abs = base_dir.realpathAlloc(allocator, static_dir_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(static_abs);

    if (pathsOverlap(out_abs, static_abs)) return error.StaticDirOverlapsOutDir;
}

fn pathsOverlap(a: []const u8, b: []const u8) bool {
    return pathContains(a, b) or pathContains(b, a);
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

fn copyStaticAssets(allocator: std.mem.Allocator, base_dir: std.fs.Dir, out_dir: std.fs.Dir, static_dir_path: []const u8) !void {
    var static_dir = base_dir.openDir(static_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer static_dir.close();

    try copyDirRecursive(allocator, static_dir, out_dir);
}

fn copyDirRecursive(allocator: std.mem.Allocator, src_root: std.fs.Dir, dst_root: std.fs.Dir) !void {
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

        var src_dir: std.fs.Dir = src_root;
        var dst_dir: std.fs.Dir = dst_root;
        var close_dirs = false;
        if (rel_path.len != 0) {
            src_dir = try src_root.openDir(rel_path, .{ .iterate = true });
            dst_dir = try dst_root.openDir(rel_path, .{ .iterate = true });
            close_dirs = true;
        }
        defer if (close_dirs) {
            src_dir.close();
            dst_dir.close();
        };

        var it = src_dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
            switch (entry.kind) {
                .file => try src_dir.copyFile(entry.name, dst_dir, entry.name, .{}),
                .directory => {
                    try dst_dir.makePath(entry.name);

                    const child_rel_path = child_rel_path: {
                        if (rel_path.len == 0) break :child_rel_path try allocator.dupe(u8, entry.name);
                        break :child_rel_path try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ rel_path, std.fs.path.sep, entry.name });
                    };
                    stack.append(allocator, child_rel_path) catch |err| {
                        allocator.free(child_rel_path);
                        return err;
                    };
                },
                else => continue,
            }
        }
    }
}

fn generatePostPage(
    allocator: std.mem.Allocator,
    out_dir: std.fs.Dir,
    out_name: []const u8,
    title: []const u8,
    date_raw: []const u8,
    markdown: []const u8,
) !void {
    var buf: [16 * 1024]u8 = undefined;
    var out_file = try out_dir.atomicFile(out_name, .{ .write_buffer = &buf });
    defer out_file.deinit();

    try writeDocumentStart(&out_file.file_writer.interface, title);
    try out_file.file_writer.interface.writeAll("<main>\n<p><a href=\"index.html\">Back</a></p>\n<h1>");
    try writeEscapedHtml(&out_file.file_writer.interface, title);
    try out_file.file_writer.interface.writeAll("</h1>\n<p><small><time datetime=\"");
    try writeEscapedHtml(&out_file.file_writer.interface, date_raw);
    try out_file.file_writer.interface.writeAll("\">");
    try writeEscapedHtml(&out_file.file_writer.interface, date_raw);
    try out_file.file_writer.interface.writeAll("</time></small></p>\n<article>\n");

    const html = try markdown_renderer.renderHtmlAlloc(allocator, markdown);
    defer allocator.free(html);
    try out_file.file_writer.interface.writeAll(html);
    try out_file.file_writer.interface.writeAll("\n</article>\n</main>\n");
    try writeDocumentEnd(&out_file.file_writer.interface);
    try out_file.finish();
}

fn writeDocumentStart(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<link rel="stylesheet" href="style.css">
        \\<title>
    );
    try writeEscapedHtml(w, title);
    try w.writeAll(
        \\</title>
        \\</head>
        \\<body>
        \\
    );
}

fn writeDocumentEnd(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\</body>
        \\</html>
        \\
    );
}

fn writeEscapedHtml(w: *std.Io.Writer, input: []const u8) !void {
    var start: usize = 0;
    for (input, 0..) |c, i| {
        const escaped: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (escaped) |esc| {
            if (i > start) try w.writeAll(input[start..i]);
            try w.writeAll(esc);
            start = i + 1;
        }
    }
    if (start < input.len) try w.writeAll(input[start..]);
}

fn slugify(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var prev_was_dash = false;
    for (input) |raw| {
        const c = std.ascii.toLower(raw);
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        if (is_alnum) {
            try out.append(allocator, c);
            prev_was_dash = false;
            continue;
        }

        if (out.items.len == 0 or prev_was_dash) continue;
        try out.append(allocator, '-');
        prev_was_dash = true;
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        out.items.len -= 1;
    }

    if (out.items.len == 0) try out.appendSlice(allocator, "post");
    return out.toOwnedSlice(allocator);
}

test "cleanDist preserves .gitignore" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("dist");
    var dist = try tmp.dir.openDir("dist", .{ .iterate = true });
    defer dist.close();

    try dist.writeFile(.{ .sub_path = ".gitignore", .data = "*\n" });
    try dist.writeFile(.{ .sub_path = "old.html", .data = "old\n" });

    try cleanDist(dist);

    try dist.access(".gitignore", .{});
    try testing.expectError(error.FileNotFound, dist.access("old.html", .{}));
}

test "cleanDist does not follow symlinks" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("dist");
    try tmp.dir.makePath("victim");
    try tmp.dir.writeFile(.{ .sub_path = "victim/keep.txt", .data = "keep\n" });

    var dist = try tmp.dir.openDir("dist", .{ .iterate = true });
    defer dist.close();

    try dist.writeFile(.{ .sub_path = ".gitignore", .data = "*\n" });
    try dist.symLink("../victim", "victim_link", .{ .is_directory = true });

    try cleanDist(dist);

    try tmp.dir.access("victim/keep.txt", .{});
    try testing.expectError(error.FileNotFound, dist.access("victim_link", .{}));
}

test "writeEscapedHtml escapes special characters" {
    const testing = std.testing;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeEscapedHtml(&aw.writer, "<&>\"'");
    try testing.expectEqualStrings("&lt;&amp;&gt;&quot;&#39;", aw.writer.buffered());
}

test "slugify produces safe, deterministic slugs" {
    const testing = std.testing;

    const slug = try slugify(testing.allocator, "\"><script>alert(1)</script>");
    defer testing.allocator.free(slug);

    try testing.expectEqualStrings("script-alert-1-script", slug);
}

test "generate sorts posts" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("posts");
    try tmp.dir.writeFile(.{ .sub_path = "posts/b.md", .data = 
        \\---
        \\title: B
        \\date: 2025-12-02
        \\---
        \\b
    });
    try tmp.dir.writeFile(.{ .sub_path = "posts/a.md", .data = 
        \\---
        \\title: A
        \\date: 2025-12-01
        \\---
        \\a
    });

    try generate(testing.allocator, tmp.dir, .{});

    const index = try tmp.dir.readFileAlloc(testing.allocator, "dist/index.html", 1024 * 1024);
    defer testing.allocator.free(index);

    const a_pos = std.mem.indexOf(u8, index, "href=\"a.html\"") orelse return error.TestExpectedEqual;
    const b_pos = std.mem.indexOf(u8, index, "href=\"b.html\"") orelse return error.TestExpectedEqual;
    try testing.expect(b_pos < a_pos);
}

test "generate writes feed.xml with correct base_url, dates, and descriptions" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("posts");
    try tmp.dir.writeFile(.{ .sub_path = "posts/one.md", .data = 
        \\---
        \\title: One & <Two>
        \\date: 2025-12-13
        \\description: Desc & <b>
        \\---
        \\one
    });

    try generate(testing.allocator, tmp.dir, .{
        .base_url = "https://example.com/blog",
        .site_title = "Example",
        .site_description = "Example desc",
    });

    const feed = try tmp.dir.readFileAlloc(testing.allocator, "dist/feed.xml", 1024 * 1024);
    defer testing.allocator.free(feed);

    try testing.expect(std.mem.indexOf(u8, feed, "<rss version=\"2.0\">") != null);
    try testing.expect(std.mem.indexOf(u8, feed, "<link>https://example.com/blog</link>") != null);
    try testing.expect(std.mem.indexOf(u8, feed, "<link>https://example.com/blog/one.html</link>") != null);
    try testing.expect(std.mem.indexOf(u8, feed, "<pubDate>Sat, 13 Dec 2025 00:00:00 GMT</pubDate>") != null);
    try testing.expect(std.mem.indexOf(u8, feed, "<description>Desc &amp; &lt;b&gt;</description>") != null);
    try testing.expect(std.mem.indexOf(u8, feed, "<title>One &amp; &lt;Two&gt;</title>") != null);
}

test "generate rejects overlapping static and output directories" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.StaticDirOverlapsOutDir, generate(testing.allocator, tmp.dir, .{
        .out_dir_path = "dist",
        .static_dir_path = "dist",
        .log_warnings = false,
    }));

    try testing.expectError(error.StaticDirOverlapsOutDir, generate(testing.allocator, tmp.dir, .{
        .out_dir_path = "dist",
        .static_dir_path = ".",
        .log_warnings = false,
    }));
}

test "generate skips drafts" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("posts");
    try tmp.dir.writeFile(.{ .sub_path = "posts/public.md", .data = 
        \\---
        \\title: Public
        \\date: 2025-12-01
        \\---
        \\hi
    });
    try tmp.dir.writeFile(.{ .sub_path = "posts/draft.md", .data = 
        \\---
        \\title: Draft
        \\date: 2025-12-02
        \\draft: true
        \\---
        \\secret
    });

    try generate(testing.allocator, tmp.dir, .{});

    const index = try tmp.dir.readFileAlloc(testing.allocator, "dist/index.html", 1024 * 1024);
    defer testing.allocator.free(index);

    try testing.expect(std.mem.indexOf(u8, index, "Public") != null);
    try testing.expect(std.mem.indexOf(u8, index, "Draft") == null);

    try tmp.dir.access("dist/public.html", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access("dist/draft.html", .{}));
}

test "generate errors on duplicate slugs" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("posts");
    try tmp.dir.writeFile(.{ .sub_path = "posts/one.md", .data = 
        \\---
        \\title: One
        \\date: 2025-12-01
        \\slug: same
        \\---
        \\hi
    });
    try tmp.dir.writeFile(.{ .sub_path = "posts/two.md", .data = 
        \\---
        \\title: Two
        \\date: 2025-12-02
        \\slug: same
        \\---
        \\hi
    });

    try testing.expectError(error.DuplicateSlug, generate(testing.allocator, tmp.dir, .{ .log_warnings = false }));
}

test "generatePostPage renders markdown to HTML" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("dist");
    var dist = try tmp.dir.openDir("dist", .{ .iterate = true });
    defer dist.close();

    try generatePostPage(testing.allocator, dist, "post.html", "Post", "2025-12-01",
        \\# Hello
        \\
        \\This is **bold**.
        \\
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
    );

    const html = try tmp.dir.readFileAlloc(testing.allocator, "dist/post.html", 1024 * 1024);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "href=\"style.css\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<strong>bold</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<table") != null);
}

test "generate copies static assets" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("static/images");
    try tmp.dir.writeFile(.{ .sub_path = "static/style.css", .data = "body{}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "static/images/logo.png", .data = "x" });

    try tmp.dir.makePath("posts");
    try tmp.dir.writeFile(.{ .sub_path = "posts/a.md", .data = 
        \\---
        \\title: A
        \\date: 2025-12-01
        \\---
        \\hi
    });

    try generate(testing.allocator, tmp.dir, .{});

    try tmp.dir.access("dist/style.css", .{});
    try tmp.dir.access("dist/images/logo.png", .{});
}
