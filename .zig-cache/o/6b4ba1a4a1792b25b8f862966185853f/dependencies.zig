pub const packages = struct {
    pub const @"clap-0.10.0-oBajB8fkAQB0JvsrWLar4YZrseSZ9irFxHB7Hvy_bvxb" = struct {
        pub const build_root = "/Users/tk/.cache/zig/p/clap-0.10.0-oBajB8fkAQB0JvsrWLar4YZrseSZ9irFxHB7Hvy_bvxb";
        pub const build_zig = @import("clap-0.10.0-oBajB8fkAQB0JvsrWLar4YZrseSZ9irFxHB7Hvy_bvxb");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"htmlentities_zig-0.1.0-zV-DJCAfAwDQMPxoEXaBrDxijlyvCK7HXhz9MIgGYj5l" = struct {
        pub const build_root = "/Users/tk/.cache/zig/p/htmlentities_zig-0.1.0-zV-DJCAfAwDQMPxoEXaBrDxijlyvCK7HXhz9MIgGYj5l";
        pub const build_zig = @import("htmlentities_zig-0.1.0-zV-DJCAfAwDQMPxoEXaBrDxijlyvCK7HXhz9MIgGYj5l");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"koino-0.1.0-S9LuWlqLAgBe5tKcfhmAPAaY_l0lxZkpt70njA6BRem2" = struct {
        pub const build_root = "/Users/tk/.cache/zig/p/koino-0.1.0-S9LuWlqLAgBe5tKcfhmAPAaY_l0lxZkpt70njA6BRem2";
        pub const build_zig = @import("koino-0.1.0-S9LuWlqLAgBe5tKcfhmAPAaY_l0lxZkpt70njA6BRem2");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zunicode", "zunicode-0.1.0-AAAAAAn0BQAjplm0OqOuLlE2kcI8p65nBybLoZwsjBrH" },
            .{ "clap", "clap-0.10.0-oBajB8fkAQB0JvsrWLar4YZrseSZ9irFxHB7Hvy_bvxb" },
            .{ "libpcre_zig", "libpcre_zig-0.1.0-Dtf6CQg4AACWtDDhtI-rjGGLKdBowMQiQrK1O5sx5icv" },
            .{ "htmlentities_zig", "htmlentities_zig-0.1.0-zV-DJCAfAwDQMPxoEXaBrDxijlyvCK7HXhz9MIgGYj5l" },
        };
    };
    pub const @"libpcre_zig-0.1.0-Dtf6CQg4AACWtDDhtI-rjGGLKdBowMQiQrK1O5sx5icv" = struct {
        pub const build_root = "/Users/tk/.cache/zig/p/libpcre_zig-0.1.0-Dtf6CQg4AACWtDDhtI-rjGGLKdBowMQiQrK1O5sx5icv";
        pub const build_zig = @import("libpcre_zig-0.1.0-Dtf6CQg4AACWtDDhtI-rjGGLKdBowMQiQrK1O5sx5icv");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "pcre", "pcre-8.45.0-AAAAAN3FlADQe8mToDeNIJ0RXIk30ytiW7cNOsnvmXXv" },
        };
    };
    pub const @"pcre-8.45.0-AAAAAN3FlADQe8mToDeNIJ0RXIk30ytiW7cNOsnvmXXv" = struct {
        pub const build_root = "/Users/tk/.cache/zig/p/pcre-8.45.0-AAAAAN3FlADQe8mToDeNIJ0RXIk30ytiW7cNOsnvmXXv";
        pub const build_zig = @import("pcre-8.45.0-AAAAAN3FlADQe8mToDeNIJ0RXIk30ytiW7cNOsnvmXXv");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zunicode-0.1.0-AAAAAAn0BQAjplm0OqOuLlE2kcI8p65nBybLoZwsjBrH" = struct {
        pub const build_root = "/Users/tk/.cache/zig/p/zunicode-0.1.0-AAAAAAn0BQAjplm0OqOuLlE2kcI8p65nBybLoZwsjBrH";
        pub const build_zig = @import("zunicode-0.1.0-AAAAAAn0BQAjplm0OqOuLlE2kcI8p65nBybLoZwsjBrH");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "koino", "koino-0.1.0-S9LuWlqLAgBe5tKcfhmAPAaY_l0lxZkpt70njA6BRem2" },
};
