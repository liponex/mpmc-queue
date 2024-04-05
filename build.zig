const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("queue", .{
        .root_source_file = .{ .path = "src/mpmc_queue.zig" },
    });

    const lib = b.addStaticLibrary(.{
        .name = "mpmc_queue",
        .root_source_file = .{ .path = "src/mpmc_queue.zig" },
        .target = target,
        .optimize = optimize,
        .version = .{
            .major = 0,
            .minor = 1,
            .patch = 0,
        },
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/mpmc_queue.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_unit_tests.step);
}
