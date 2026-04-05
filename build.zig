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

    // Build-time options for the library and dependents
    const sentry_build_opts = b.addOptions();
    sentry_build_opts.addOption([]const u8, "sentry_project_root", b.pathFromRoot("."));

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sentry_zig",
        .root_module = lib_mod,
    });

    // Expose build options module to the library
    lib.root_module.addOptions("sentry_build", sentry_build_opts);

    const types = b.addModule("types", .{
        .root_source_file = b.path("src/Types.zig"),
    });

    lib.root_module.addImport("types", types);
    types.addImport("utils", lib_mod);

    // IMPORTANT: Expose the module for external packages
    // This allows other packages to import sentry_zig via b.dependency().module()
    _ = b.addModule("sentry_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types },
            .{ .name = "sentry_build", .module = sentry_build_opts.createModule() },
        },
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Examples
    addExample(b, target, optimize, lib, "panic_handler", "Panic handler example");
    addExample(b, target, optimize, lib, "capture_message", "Run the captureMessage demo");
    addExample(b, target, optimize, lib, "capture_error", "Run the captureError demo");

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    lib_unit_tests.root_module.addImport("types", types);
    lib_unit_tests.root_module.addOptions("sentry_build", sentry_build_opts);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

/// Helper function to create an example executable with consistent configuration
fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Step.Compile,
    name: []const u8,
    description: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
    });

    // Link the sentry_zig library as a user would
    exe.linkLibrary(lib);

    // Add sentry_zig as a module dependency (as users would do)
    exe.root_module.addImport("sentry_zig", lib.root_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const step = b.step(name, description);
    step.dependOn(&run_cmd.step);
}
