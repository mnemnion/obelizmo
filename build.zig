const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export as module to be available for @import("obelizmo") on user site
    const obelizmo_module = b.addModule("obelizmo", .{
        .root_source_file = b.path("src/obelizmo.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Export colors module separately, to be available for @import("colors") in user code
    const colors_module = b.addModule("colors", .{
        .root_source_file = b.path("src/color_marks.zig"),
        .target = target,
        .optimize = optimize,
    });
    obelizmo_module.addImport("colors", colors_module);
    obelizmo_module.addImport("mvzr", b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    }).module("mvzr"));

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const run_tests = std.Build.Step.Run.create(b, "snapshot tests");
    run_tests.addFileArg2(.zig_exe, .{});
    run_tests.addArgs(&.{ "build", "test" });
    run_tests.setCwd(b.path("tests"));
    run_tests.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    run_tests.addArg(b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}));
    run_tests.addArg(b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")}));
    for (test_filters) |filter| run_tests.addArg(b.fmt("-Dtest-filter={s}", .{filter}));
    run_tests.has_side_effects = true;
    b.step("test", "Run unit and snapshot tests").dependOn(&run_tests.step);
}
