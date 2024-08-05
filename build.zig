const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Export as module to be available for @import("obelizmo") on user site
    _ = b.addModule("obelizmo", .{
        .root_source_file = b.path("src/obelizmo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/obelizmo.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        lib_unit_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
