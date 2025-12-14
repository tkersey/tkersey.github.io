const std = @import("std");

const scalars = @import("scalars.zig");

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn parseIso8601(input: []const u8) !Date {
        if (input.len != 10) return error.FrontMatterInvalidDate;
        if (input[4] != '-' or input[7] != '-') return error.FrontMatterInvalidDate;

        const year = std.fmt.parseInt(i32, input[0..4], 10) catch return error.FrontMatterInvalidDate;
        const month = std.fmt.parseInt(u8, input[5..7], 10) catch return error.FrontMatterInvalidDate;
        const day = std.fmt.parseInt(u8, input[8..10], 10) catch return error.FrontMatterInvalidDate;

        if (month < 1 or month > 12) return error.FrontMatterInvalidDate;
        const max_day = daysInMonth(year, month) orelse return error.FrontMatterInvalidDate;
        if (day < 1 or day > max_day) return error.FrontMatterInvalidDate;

        return .{ .year = year, .month = month, .day = day };
    }

    fn daysInMonth(year: i32, month: u8) ?u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => null,
        };
    }

    fn isLeapYear(year: i32) bool {
        if (@mod(year, @as(i32, 400)) == 0) return true;
        if (@mod(year, @as(i32, 100)) == 0) return false;
        return @mod(year, @as(i32, 4)) == 0;
    }
};

pub const FrontMatter = struct {
    title: []const u8,
    date_raw: []const u8,
    date: Date,
    description: ?[]const u8 = null,
    tags: std.ArrayListUnmanaged([]const u8) = .{},
    draft: bool = false,
    slug: ?[]const u8 = null,

    pub fn deinit(self: *FrontMatter, allocator: std.mem.Allocator) void {
        self.tags.deinit(allocator);
    }
};

pub const ParsedPost = struct {
    raw: []u8,
    front_matter: FrontMatter,
    body: []const u8,

    pub fn deinit(self: *ParsedPost, allocator: std.mem.Allocator) void {
        self.front_matter.deinit(allocator);
        allocator.free(self.raw);
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !ParsedPost {
    const raw = try allocator.dupe(u8, input);
    return parseOwnedBuffer(allocator, raw);
}

pub fn parseOwnedBuffer(allocator: std.mem.Allocator, raw: []u8) !ParsedPost {
    errdefer allocator.free(raw);

    const split = try splitFrontMatter(raw);
    var fm = try parseFrontMatter(allocator, split.front_matter);
    errdefer fm.deinit(allocator);

    return .{ .raw = raw, .front_matter = fm, .body = split.body };
}

pub const Split = struct {
    front_matter: []const u8,
    body: []const u8,
};

pub fn splitFrontMatter(input: []const u8) !Split {
    var start: usize = 0;
    if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) start = 3;

    const first_line_end = std.mem.indexOfScalarPos(u8, input, start, '\n') orelse input.len;
    const first_line = input[start..first_line_end];
    if (!isDelimiterLine(first_line)) return error.FrontMatterMissingOpenDelimiter;

    const fm_start = if (first_line_end < input.len) first_line_end + 1 else input.len;
    var pos = fm_start;
    while (pos <= input.len) {
        const line_end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
        const line = input[pos..line_end];
        if (isDelimiterLine(line)) {
            const body_start = if (line_end < input.len) line_end + 1 else input.len;
            return .{
                .front_matter = input[fm_start..pos],
                .body = input[body_start..],
            };
        }

        if (line_end == input.len) break;
        pos = line_end + 1;
    }

    return error.FrontMatterMissingCloseDelimiter;
}

fn isDelimiterLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, line, "\r"), " \t");
    return std.mem.eql(u8, trimmed, "---");
}

fn parseFrontMatter(allocator: std.mem.Allocator, input: []const u8) !FrontMatter {
    var title: ?[]const u8 = null;
    var date_raw: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var draft = false;
    var slug: ?[]const u8 = null;
    var tags: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer tags.deinit(allocator);

    var list_key: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        if (list_key) |key| {
            if (std.mem.startsWith(u8, trimmed, "-")) {
                const item_raw = std.mem.trimLeft(u8, trimmed[1..], " \t");
                const item = scalars.parseScalar(scalars.stripInlineComment(item_raw));
                if (std.mem.eql(u8, key, "tags")) try tags.append(allocator, item);
                continue;
            }
            list_key = null;
        }

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.FrontMatterInvalidSyntax;
        const key = std.mem.trimRight(u8, trimmed[0..colon], " \t");
        var value = std.mem.trimLeft(u8, trimmed[colon + 1 ..], " \t");
        value = scalars.stripInlineComment(value);

        if (value.len == 0) {
            if (std.mem.eql(u8, key, "tags")) {
                list_key = key;
                continue;
            }
            return error.FrontMatterInvalidSyntax;
        }

        if (std.mem.eql(u8, key, "tags")) {
            if (value[0] == '[') {
                try parseInlineList(allocator, &tags, value);
            } else {
                try tags.append(allocator, scalars.parseScalar(value));
            }
            continue;
        }

        const scalar = scalars.parseScalar(value);
        if (std.mem.eql(u8, key, "title")) {
            title = scalar;
            continue;
        }
        if (std.mem.eql(u8, key, "date")) {
            date_raw = scalar;
            continue;
        }
        if (std.mem.eql(u8, key, "description")) {
            description = scalar;
            continue;
        }
        if (std.mem.eql(u8, key, "draft")) {
            draft = parseBool(scalar) catch return error.FrontMatterInvalidBool;
            continue;
        }
        if (std.mem.eql(u8, key, "slug")) {
            slug = scalar;
            continue;
        }
    }

    const title_val = title orelse return error.FrontMatterMissingTitle;
    const date_str = date_raw orelse return error.FrontMatterMissingDate;
    const date = Date.parseIso8601(date_str) catch return error.FrontMatterInvalidDate;

    return .{
        .title = title_val,
        .date_raw = date_str,
        .date = date,
        .description = description,
        .tags = tags,
        .draft = draft,
        .slug = slug,
    };
}

fn parseBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no")) return false;
    return error.FrontMatterInvalidBool;
}

fn parseInlineList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.FrontMatterInvalidSyntax;

    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return;

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw_item| {
        const item = scalars.parseScalar(raw_item);
        if (item.len == 0) continue;
        try list.append(allocator, item);
    }
}

test "parse extracts required fields and tags list" {
    const testing = std.testing;

    const md =
        \\---
        \\title: Hello, world
        \\date: "2025-12-13"
        \\description: First post
        \\tags:
        \\  - meta
        \\  - zig
        \\---
        \\
        \\Body.
    ;

    var parsed = try parse(testing.allocator, md);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("Hello, world", parsed.front_matter.title);
    try testing.expectEqualStrings("2025-12-13", parsed.front_matter.date_raw);
    try testing.expectEqual(@as(i32, 2025), parsed.front_matter.date.year);
    try testing.expectEqual(@as(u8, 12), parsed.front_matter.date.month);
    try testing.expectEqual(@as(u8, 13), parsed.front_matter.date.day);
    try testing.expectEqualStrings("First post", parsed.front_matter.description.?);
    try testing.expectEqual(@as(usize, 2), parsed.front_matter.tags.items.len);
    try testing.expectEqualStrings("meta", parsed.front_matter.tags.items[0]);
    try testing.expectEqualStrings("zig", parsed.front_matter.tags.items[1]);
    try testing.expect(!parsed.front_matter.draft);
    try testing.expect(parsed.front_matter.slug == null);
    try testing.expect(std.mem.indexOf(u8, parsed.body, "Body.") != null);
}

test "parse supports trailing comments after quoted scalars" {
    const testing = std.testing;

    const md =
        \\---
        \\title: "Hello" # comment
        \\date: "2025-12-13" # another
        \\tags:
        \\  - zig # trailing
        \\---
        \\ok
    ;

    var parsed = try parse(testing.allocator, md);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("Hello", parsed.front_matter.title);
    try testing.expectEqualStrings("2025-12-13", parsed.front_matter.date_raw);
    try testing.expectEqualStrings("zig", parsed.front_matter.tags.items[0]);
}

test "parse rejects invalid calendar dates" {
    const testing = std.testing;

    const md =
        \\---
        \\title: X
        \\date: 2025-02-31
        \\---
        \\hi
    ;

    try testing.expectError(error.FrontMatterInvalidDate, parse(testing.allocator, md));
}

test "parse rejects extended date strings" {
    const testing = std.testing;

    const md =
        \\---
        \\title: X
        \\date: 2025-12-01T00:00:00Z
        \\---
        \\hi
    ;

    try testing.expectError(error.FrontMatterInvalidDate, parse(testing.allocator, md));
}

test "parse rejects missing-value non-list keys" {
    const testing = std.testing;

    const md =
        \\---
        \\title: X
        \\date: 2025-12-01
        \\description:
        \\---
        \\hi
    ;

    try testing.expectError(error.FrontMatterInvalidSyntax, parse(testing.allocator, md));
}

test "parse returns owned slices (caller can free input)" {
    const testing = std.testing;

    const md =
        \\---
        \\title: Hello
        \\date: 2025-12-13
        \\---
        \\Body
    ;

    const buf = try testing.allocator.dupe(u8, md);

    var parsed = parse(testing.allocator, buf) catch |err| {
        testing.allocator.free(buf);
        return err;
    };
    // Free caller buffer to prove `parsed` is independent.
    testing.allocator.free(buf);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("Hello", parsed.front_matter.title);
    try testing.expect(std.mem.indexOf(u8, parsed.body, "Body") != null);
}

test "parse supports inline tags" {
    const testing = std.testing;

    const md =
        \\---
        \\title: X
        \\date: 2025-12-01
        \\tags: [meta, zig]
        \\---
        \\hi
    ;

    var parsed = try parse(testing.allocator, md);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.front_matter.tags.items.len);
    try testing.expectEqualStrings("meta", parsed.front_matter.tags.items[0]);
    try testing.expectEqualStrings("zig", parsed.front_matter.tags.items[1]);
}

test "splitFrontMatter requires closing delimiter" {
    const testing = std.testing;

    const md =
        \\---
        \\title: X
        \\date: 2025-12-01
    ;

    try testing.expectError(error.FrontMatterMissingCloseDelimiter, splitFrontMatter(md));
}
