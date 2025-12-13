const std = @import("std");

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
        var it = pd.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const stem = entry.name[0 .. entry.name.len - 3];
            const html_name = try std.fmt.allocPrint(allocator, "{s}.html", .{stem});
            defer allocator.free(html_name);

            try generatePostPage(allocator, pd.*, out_dir, entry.name, html_name, stem);

            try index_writer.interface.print(
                "<li><a href=\"/{s}\">{s}</a></li>\n",
                .{ html_name, stem },
            );
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
    posts_dir: std.fs.Dir,
    out_dir: std.fs.Dir,
    md_name: []const u8,
    out_name: []const u8,
    title: []const u8,
) !void {
    const md = try posts_dir.readFileAlloc(allocator, md_name, 10 * 1024 * 1024);
    defer allocator.free(md);

    var out_file = try out_dir.createFile(out_name, .{ .truncate = true });
    defer out_file.close();

    var buf: [16 * 1024]u8 = undefined;
    var w = out_file.writer(&buf);

    try w.interface.print(
        \\<!doctype html>
        \\<meta charset="utf-8">
        \\<title>{s}</title>
        \\<p><a href="/index.html">Back</a></p>
        \\<pre>
        \\
    , .{title});

    try writeEscapedHtml(&w.interface, md);
    try w.interface.writeAll("\n</pre>\n");
    try w.interface.flush();
}

fn writeEscapedHtml(w: *std.Io.Writer, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeAll(&[_]u8{c}),
        }
    }
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
