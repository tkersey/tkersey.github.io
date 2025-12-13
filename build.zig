const std = @import("std");

pub fn build(b: *std.Build) void {
    const user_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (!user_target.query.isNative()) {
        std.log.warn("'-Dtarget' is ignored: the `blog` binary is a build-time tool that must run on the host", .{});
    }

    const host_target = b.resolveTargetQuery(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "blog",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the blog CLI");
    run_step.dependOn(&run_cmd.step);

    const build_site_cmd = b.addRunArtifact(exe);
    build_site_cmd.step.dependOn(b.getInstallStep());
    build_site_cmd.addArg("build");
    const build_site_step = b.step("build", "Generate the site into dist/");
    build_site_step.dependOn(&build_site_cmd.step);
    b.default_step = build_site_step;

    const serve_cmd = b.addRunArtifact(exe);
    serve_cmd.step.dependOn(b.getInstallStep());
    serve_cmd.addArg("serve");
    const serve_step = b.step("serve", "Serve dist/ locally");
    serve_step.dependOn(&serve_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    inline for (.{ "src/cli.zig", "src/site.zig", "src/server.zig" }) |test_root| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(test_root),
            .target = host_target,
            .optimize = optimize,
        });
        const test_exe = b.addTest(.{ .root_module = test_module });
        const run_test = b.addRunArtifact(test_exe);
        test_step.dependOn(&run_test.step);
    }
}
