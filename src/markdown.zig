const std = @import("std");

const c = @cImport({
    @cInclude("cmark-gfm.h");
    @cInclude("cmark-gfm-core-extensions.h");
    @cInclude("cmark-gfm-extension_api.h");
});

fn ensureCoreExtensionsRegistered() void {
    c.cmark_gfm_core_extensions_ensure_registered();
}

var core_extensions_once = std.once(ensureCoreExtensionsRegistered);

/// Render Markdown as an HTML fragment.
/// Returns an owned slice; caller must free it with `allocator.free`.
pub fn renderHtmlAlloc(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    core_extensions_once.call();

    if (!std.unicode.utf8ValidateSlice(markdown)) return error.InvalidUtf8;

    const mem = c.cmark_get_default_mem_allocator();
    const free_fn = mem.*.free orelse return error.MissingDefaultAllocatorFree;

    const options: c_int = c.CMARK_OPT_DEFAULT;
    const parser = c.cmark_parser_new(options) orelse return error.OutOfMemory;
    defer c.cmark_parser_free(parser);

    const extensions = [_][*:0]const u8{
        "table",
        "strikethrough",
        "autolink",
        "tasklist",
        "tagfilter",
    };
    inline for (extensions) |name| {
        const ext = c.cmark_find_syntax_extension(name) orelse return error.MissingExtension;
        if (c.cmark_parser_attach_syntax_extension(parser, ext) == 0) return error.AttachFailed;
    }

    c.cmark_parser_feed(parser, markdown.ptr, markdown.len);
    const doc = c.cmark_parser_finish(parser) orelse return error.ParseFailed;
    defer c.cmark_node_free(doc);

    const syntax_extensions = c.cmark_parser_get_syntax_extensions(parser);
    const rendered = c.cmark_render_html(doc, options, syntax_extensions) orelse return error.RenderFailed;
    defer free_fn(@ptrCast(rendered));

    return allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(rendered))));
}

test "renderHtmlAlloc scrubs raw HTML and dangerous URLs" {
    const testing = std.testing;

    const input =
        \\<script>alert(1)</script>
        \\
        \\[x](javascript:alert(1))
        \\
    ;

    const html = try renderHtmlAlloc(testing.allocator, input);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, html, "javascript:") == null);
}

test "renderHtmlAlloc rejects invalid UTF-8" {
    const testing = std.testing;

    try testing.expectError(error.InvalidUtf8, renderHtmlAlloc(testing.allocator, "abc\xc0"));
}
