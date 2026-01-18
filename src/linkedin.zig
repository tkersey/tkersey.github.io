const std = @import("std");

const front_matter = @import("front_matter.zig");
const site = @import("site.zig");

const max_post_bytes: usize = 10 * 1024 * 1024;

pub const Post = struct {
    path: []const u8,
    parsed: front_matter.ParsedPost,
    slug: []u8,
    url: []u8,

    pub fn deinit(self: *Post, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.slug);
        allocator.free(self.url);
        self.parsed.deinit(allocator);
        self.* = undefined;
    }
};

pub const PostResult = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *PostResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const TokenResult = struct {
    status: std.http.Status,
    body: []u8,
    access_token: ?[]u8,
    expires_in: ?i64,

    pub fn deinit(self: *TokenResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.access_token) |token| allocator.free(token);
        self.* = undefined;
    }
};

pub const FetchAuthorResult = struct {
    status: std.http.Status,
    body: []u8,
    person_id: ?[]u8,

    pub fn deinit(self: *FetchAuthorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.person_id) |id| allocator.free(id);
        self.* = undefined;
    }
};

pub fn loadPost(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    path: []const u8,
    base_url: []const u8,
) !?Post {
    const raw = try base_dir.readFileAlloc(allocator, path, max_post_bytes);
    var parsed = front_matter.parseOwnedBuffer(allocator, raw) catch |err| {
        allocator.free(raw);
        return err;
    };
    errdefer parsed.deinit(allocator);

    if (parsed.front_matter.draft) {
        parsed.deinit(allocator);
        return null;
    }

    const base_slug_input = parsed.front_matter.slug orelse std.fs.path.stem(path);
    const slug = try site.slugify(allocator, base_slug_input);
    errdefer allocator.free(slug);

    const trimmed_base = std.mem.trimRight(u8, base_url, "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ trimmed_base, slug });
    errdefer allocator.free(url);

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    return .{
        .path = owned_path,
        .parsed = parsed,
        .slug = slug,
        .url = url,
    };
}

pub fn findLatestPost(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    posts_dir: []const u8,
    base_url: []const u8,
) !?Post {
    var dir = base_dir.openDir(posts_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    var best: ?Post = null;

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ posts_dir, entry.name });
        defer allocator.free(rel_path);

        const maybe_post = try loadPost(allocator, base_dir, rel_path, base_url);
        if (maybe_post == null) continue;

        var post = maybe_post.?;
        if (best == null or isNewer(post, best.?)) {
            if (best) |*prev| prev.deinit(allocator);
            best = post;
        } else {
            post.deinit(allocator);
        }
    }

    return best;
}

pub fn composeShareText(
    allocator: std.mem.Allocator,
    post: *const Post,
    max_chars: usize,
    max_hashtags: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, post.parsed.front_matter.title);

    if (post.parsed.front_matter.description) |desc| {
        if (desc.len != 0) {
            try out.appendSlice(allocator, "\n\n");
            try out.appendSlice(allocator, desc);
        }
    }

    try out.appendSlice(allocator, "\n\n");
    try out.appendSlice(allocator, post.url);

    if (max_hashtags > 0) {
        var added: usize = 0;
        for (post.parsed.front_matter.tags.items) |tag| {
            if (added >= max_hashtags) break;
            const trimmed = std.mem.trim(u8, tag, " \t");
            if (trimmed.len == 0) continue;
            if (!hasAlnum(trimmed)) continue;

            const slug = try site.slugify(allocator, trimmed);
            defer allocator.free(slug);

            if (added == 0) {
                try out.appendSlice(allocator, "\n\n");
            } else {
                try out.appendSlice(allocator, " ");
            }

            try out.appendSlice(allocator, "#");
            try out.appendSlice(allocator, slug);
            added += 1;
        }
    }

    truncateUtf8InPlace(&out, max_chars);
    return out.toOwnedSlice(allocator);
}

pub fn postToLinkedIn(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    access_token: []const u8,
    author_urn: []const u8,
    share_text: []const u8,
    title: []const u8,
    description: ?[]const u8,
    url: []const u8,
) !PostResult {
    var payload = std.Io.Writer.Allocating.init(allocator);
    defer payload.deinit();

    try writeUgcPayload(&payload.writer, author_urn, share_text, title, description, url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var response_buf = std.Io.Writer.Allocating.init(allocator);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://api.linkedin.com/v2/ugcPosts" },
        .method = .POST,
        .payload = payload.written(),
        .headers = .{
            .authorization = .{ .override = auth_header },
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "blog/1.0" },
        },
        .extra_headers = &.{
            .{ .name = "X-Restli-Protocol-Version", .value = "2.0.0" },
        },
        .response_writer = &response_buf.writer,
    });

    return .{
        .status = result.status,
        .body = try response_buf.toOwnedSlice(),
    };
}

pub fn buildAuthUrl(
    allocator: std.mem.Allocator,
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    scope: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try out.writer.writeAll("https://www.linkedin.com/oauth/v2/authorization?response_type=code&client_id=");
    try writeUrlEncoded(&out.writer, client_id);
    try out.writer.writeAll("&redirect_uri=");
    try writeUrlEncoded(&out.writer, redirect_uri);
    try out.writer.writeAll("&state=");
    try writeUrlEncoded(&out.writer, state);
    try out.writer.writeAll("&scope=");
    try writeUrlEncoded(&out.writer, scope);

    return out.toOwnedSlice();
}

pub fn exchangeAuthCode(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
) !TokenResult {
    var payload = std.Io.Writer.Allocating.init(allocator);
    defer payload.deinit();

    try payload.writer.writeAll("grant_type=authorization_code&code=");
    try writeUrlEncoded(&payload.writer, code);
    try payload.writer.writeAll("&client_id=");
    try writeUrlEncoded(&payload.writer, client_id);
    try payload.writer.writeAll("&client_secret=");
    try writeUrlEncoded(&payload.writer, client_secret);
    try payload.writer.writeAll("&redirect_uri=");
    try writeUrlEncoded(&payload.writer, redirect_uri);

    var response_buf = std.Io.Writer.Allocating.init(allocator);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://www.linkedin.com/oauth/v2/accessToken" },
        .method = .POST,
        .payload = payload.written(),
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "blog/1.0" },
        },
        .response_writer = &response_buf.writer,
    });

    const body = try response_buf.toOwnedSlice();

    var access_token: ?[]u8 = null;
    var expires_in: ?i64 = null;
    if (result.status.class() == .success) {
        if (std.json.parseFromSlice(
            struct { access_token: []const u8, expires_in: ?i64 = null },
            allocator,
            body,
            .{ .ignore_unknown_fields = true },
        )) |parsed| {
            defer parsed.deinit();
            access_token = try allocator.dupe(u8, parsed.value.access_token);
            expires_in = parsed.value.expires_in;
        } else |_| {
            access_token = null;
        }
    }

    return .{
        .status = result.status,
        .body = body,
        .access_token = access_token,
        .expires_in = expires_in,
    };
}

pub fn fetchPersonId(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    access_token: []const u8,
) !FetchAuthorResult {
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var response_buf = std.Io.Writer.Allocating.init(allocator);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://api.linkedin.com/v2/me?projection=(id)" },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "blog/1.0" },
        },
        .response_writer = &response_buf.writer,
    });

    const body = try response_buf.toOwnedSlice();

    var person_id: ?[]u8 = null;
    if (result.status.class() == .success) {
        if (std.json.parseFromSlice(struct { id: []const u8 }, allocator, body, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            person_id = try allocator.dupe(u8, parsed.value.id);
        } else |_| {
            person_id = null;
        }
    }

    return .{
        .status = result.status,
        .body = body,
        .person_id = person_id,
    };
}

fn writeUgcPayload(
    writer: *std.Io.Writer,
    author_urn: []const u8,
    share_text: []const u8,
    title: []const u8,
    description: ?[]const u8,
    url: []const u8,
) !void {
    try writer.writeAll("{\"author\":");
    try std.json.Stringify.value(author_urn, .{}, writer);
    try writer.writeAll(",\"lifecycleState\":\"PUBLISHED\",\"specificContent\":{\"com.linkedin.ugc.ShareContent\":{");
    try writer.writeAll("\"shareCommentary\":{\"text\":");
    try std.json.Stringify.value(share_text, .{}, writer);
    try writer.writeAll("},\"shareMediaCategory\":\"ARTICLE\",\"media\":[{\"status\":\"READY\",\"originalUrl\":");
    try std.json.Stringify.value(url, .{}, writer);
    try writer.writeAll(",\"title\":{\"text\":");
    try std.json.Stringify.value(title, .{}, writer);
    try writer.writeAll("}");
    if (description) |desc| {
        if (desc.len != 0) {
            try writer.writeAll(",\"description\":{\"text\":");
            try std.json.Stringify.value(desc, .{}, writer);
            try writer.writeAll("}");
        }
    }
    try writer.writeAll("}]}},\"visibility\":{\"com.linkedin.ugc.MemberNetworkVisibility\":\"PUBLIC\"}}");
}

fn isNewer(candidate: Post, current: Post) bool {
    const cmp = compareDate(candidate.parsed.front_matter.date, current.parsed.front_matter.date);
    if (cmp != 0) return cmp > 0;
    return std.mem.lessThan(u8, candidate.slug, current.slug);
}

fn compareDate(a: front_matter.Date, b: front_matter.Date) i8 {
    if (a.year != b.year) return if (a.year > b.year) 1 else -1;
    if (a.month != b.month) return if (a.month > b.month) 1 else -1;
    if (a.day != b.day) return if (a.day > b.day) 1 else -1;
    return 0;
}

fn truncateUtf8InPlace(list: *std.ArrayList(u8), max_chars: usize) void {
    if (max_chars == 0) {
        list.items.len = 0;
        return;
    }

    var count: usize = 0;
    var idx: usize = 0;
    while (idx < list.items.len) {
        if (count >= max_chars) {
            list.items.len = idx;
            return;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(list.items[idx]) catch {
            list.items.len = idx;
            return;
        };
        if (idx + seq_len > list.items.len) {
            list.items.len = idx;
            return;
        }
        idx += seq_len;
        count += 1;
    }
}

fn hasAlnum(input: []const u8) bool {
    for (input) |c| {
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) return true;
    }
    return false;
}

fn writeUrlEncoded(writer: *std.Io.Writer, input: []const u8) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try writer.writeByte(c);
        } else {
            try writer.print("%{X:0>2}", .{c});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

test "truncateUtf8InPlace keeps valid utf8" {
    const testing = std.testing;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);

    try list.appendSlice(testing.allocator, "hello ☃️ world");
    truncateUtf8InPlace(&list, 8);
    try testing.expect(std.unicode.utf8ValidateSlice(list.items));
}

test "fuzz truncateUtf8InPlace never leaves invalid utf8" {
    const testing = std.testing;

    try testing.fuzz(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, input: []const u8) !void {
            const max_len = @min(input.len, 4096);
            const slice = input[0..max_len];

            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(allocator);

            try list.appendSlice(allocator, slice);
            truncateUtf8InPlace(&list, 256);

            try testing.expect(list.items.len <= slice.len);
            try testing.expect(std.unicode.utf8ValidateSlice(list.items));
        }
    }.run, .{});
}

test "buildAuthUrl encodes query params" {
    const testing = std.testing;
    const url = try buildAuthUrl(
        testing.allocator,
        "id 1",
        "http://127.0.0.1:8123/callback",
        "state",
        "r_liteprofile w_member_social",
    );
    defer testing.allocator.free(url);

    try testing.expect(std.mem.indexOf(u8, url, "client_id=id%201") != null);
    try testing.expect(std.mem.indexOf(u8, url, "scope=r_liteprofile%20w_member_social") != null);
}
