const std = @import("std");

const front_matter = @import("front_matter.zig");
const markdown_renderer = @import("markdown.zig");

pub const GenerateOptions = struct {
    out_dir_path: []const u8 = "dist",
    posts_dir_path: []const u8 = "posts",
};

pub fn generate(allocator: std.mem.Allocator, base_dir: std.fs.Dir, options: GenerateOptions) !void {
    try base_dir.makePath(options.out_dir_path);

    var out_dir = try base_dir.openDir(options.out_dir_path, .{ .iterate = true });
    defer out_dir.close();

    try cleanDist(out_dir);

    var posts_dir = base_dir.openDir(options.posts_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (posts_dir) |*d| d.close();

    var index_file = try out_dir.createFile("index.html", .{ .truncate = true });
    defer index_file.close();

    var index_buf: [16 * 1024]u8 = undefined;
    var index_writer = index_file.writer(&index_buf);

    try index_writer.interface.writeAll(
        \\<!doctype html>
        \\<meta charset="utf-8">
        \\<title>Blog</title>
        \\<h1>Posts</h1>
        \\<ul>
        \\
    );

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
        defer {
            var it_slugs = slug_owners.iterator();
            while (it_slugs.next()) |kv| allocator.free(kv.key_ptr.*);
            slug_owners.deinit(allocator);
        }

        for (post_names.items) |md_name| {
            const stem = md_name[0 .. md_name.len - 3];

            const md = pd.readFileAlloc(allocator, md_name, 10 * 1024 * 1024) catch |err| {
                std.log.warn("posts/{s}: {s}", .{ md_name, @errorName(err) });
                return err;
            };

            var parsed = front_matter.parseOwnedBuffer(allocator, md) catch |err| {
                std.log.warn("posts/{s}: {s}", .{ md_name, @errorName(err) });
                return err;
            };
            defer parsed.deinit(allocator);
            if (parsed.front_matter.draft) continue;

            const base_slug_input = parsed.front_matter.slug orelse stem;
            const slug = try slugify(allocator, base_slug_input);
            if (slug_owners.get(slug)) |owner| {
                std.log.warn(
                    "duplicate slug '{s}' for posts/{s} (already used by posts/{s})",
                    .{ slug, md_name, owner },
                );
                allocator.free(slug);
                return error.DuplicateSlug;
            }
            try slug_owners.put(allocator, slug, md_name);

            const html_name = try std.fmt.allocPrint(allocator, "{s}.html", .{slug});
            defer allocator.free(html_name);

            try generatePostPage(allocator, out_dir, html_name, parsed.front_matter.title, parsed.body);

            try index_writer.interface.writeAll("<li><a href=\"/");
            try writeEscapedHtml(&index_writer.interface, html_name);
            try index_writer.interface.writeAll("\">");
            try writeEscapedHtml(&index_writer.interface, parsed.front_matter.title);
            try index_writer.interface.writeAll("</a></li>\n");
        }
    }

    try index_writer.interface.writeAll("</ul>\n");
    try index_writer.interface.flush();
}

fn cleanDist(out_dir: std.fs.Dir) !void {
    var it = out_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
        switch (entry.kind) {
            .file => try out_dir.deleteFile(entry.name),
            .directory => try out_dir.deleteTree(entry.name),
            else => try out_dir.deleteTree(entry.name),
        }
    }
}

fn generatePostPage(
    allocator: std.mem.Allocator,
    out_dir: std.fs.Dir,
    out_name: []const u8,
    title: []const u8,
    markdown: []const u8,
) !void {
    var out_file = try out_dir.createFile(out_name, .{ .truncate = true });
    defer out_file.close();

    var buf: [16 * 1024]u8 = undefined;
    var w = out_file.writer(&buf);

    try w.interface.writeAll(
        \\<!doctype html>
        \\<meta charset="utf-8">
        \\<title>
    );
    try writeEscapedHtml(&w.interface, title);
    try w.interface.writeAll(
        \\</title>
        \\<p><a href="/index.html">Back</a></p>
        \\<main>
    );

    const html = try markdown_renderer.renderHtml(allocator, markdown);
    defer allocator.free(html);
    try w.interface.writeAll(html);
    try w.interface.writeAll("\n</main>\n");
    try w.interface.flush();
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

    const a_pos = std.mem.indexOf(u8, index, "/a.html") orelse return error.TestExpectedEqual;
    const b_pos = std.mem.indexOf(u8, index, "/b.html") orelse return error.TestExpectedEqual;
    try testing.expect(a_pos < b_pos);
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

    try testing.expectError(error.DuplicateSlug, generate(testing.allocator, tmp.dir, .{}));
}

test "generatePostPage renders markdown to HTML" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("dist");
    var dist = try tmp.dir.openDir("dist", .{ .iterate = true });
    defer dist.close();

    try generatePostPage(testing.allocator, dist, "post.html", "Post",
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

    try testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<strong>bold</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<table") != null);
}
