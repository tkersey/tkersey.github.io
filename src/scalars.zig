const std = @import("std");

pub fn stripInlineComment(value: []const u8) []const u8 {
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

pub fn parseScalar(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}
