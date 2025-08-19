const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sentry_zig",
        .root_module = lib_mod,
    });

    const types = b.addModule("types", .{
        .root_source_file = b.path("src/Types.zig"),
    });

    lib.root_module.addImport("types", types);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Create an executable that uses the library
    const exe = b.addExecutable(.{
        .name = "sentry-demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the types module to the executable
    exe.root_module.addImport("types", types);

    // Install the executable
    b.installArtifact(exe);

    // Create a run step for the executable
    const run_exe = b.addRunArtifact(exe);

    // Allow command line arguments to be passed to the executable
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    // Create a run step that can be invoked with "zig build run"
    const run_step = b.step("run", "Run the demo application");
    run_step.dependOn(&run_exe.step);
    const exe = b.addExecutable(.{
        .name = "send_empty_envelope",
        .root_source_file = b.path("src/send_empty_envelope.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(lib);
    exe.root_module.addImport("types", types);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const send_empty_envelope_step = b.step("send_empty_envelope", "Send an empty envelope");
    send_empty_envelope_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    lib_unit_tests.root_module.addImport("types", types);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
