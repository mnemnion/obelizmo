const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = .{ .target = target, .optimize = optimize };
    const obelizmo = b.dependency("obelizmo", options);
    const module = obelizmo.module("obelizmo");
    module.addImport("ohsnap", b.dependency("ohsnap", options).module("ohsnap"));
    module.addImport("ezcaper", b.dependency("ezcaper", options).module("ezcaper"));
    const filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};
    const tests = b.addTest(.{ .root_module = module, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(obelizmo.path(""));
    b.step("test", "Run unit and snapshot tests").dependOn(&run_tests.step);
}
