const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("tools/mkstore.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "mkstore", .root_module = module });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    // The store's own list, read as the workflow does.
    const list = b.addRunArtifact(exe);
    list.addArgs(&.{"list"});
    list.addFileArg(b.path("store.zon"));
    _ = list.captureStdOut(.{});
    test_step.dependOn(&list.step);
}
