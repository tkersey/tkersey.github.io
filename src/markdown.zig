const std = @import("std");

const c = @cImport({
    @cInclude("cmark-gfm.h");
    @cInclude("cmark-gfm-core-extensions.h");
    @cInclude("cmark-gfm-extension_api.h");
});

pub fn renderHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    c.cmark_gfm_core_extensions_ensure_registered();

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
    defer {
        const mem = c.cmark_get_default_mem_allocator();
        mem.*.free.?(@ptrCast(rendered));
    }

    return allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(rendered))));
}
