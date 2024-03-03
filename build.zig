const std = @import("std");

const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;

const riscv = CrossTarget{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    // Figure out how to set this to rv64g if necessary.
    .cpu_model = .determined_by_cpu_arch,
};

const mat4x4 = [4][4]f32{
    [_]f32{ 1.0, 0.0, 0.0, 0.0 },
    [_]f32{ 0.0, 1.0, 0.0, 1.0 },
    [_]f32{ 0.0, 0.0, 1.0, 0.0 },
    [_]f32{ 0.0, 0.0, 0.0, 1.0 },
};

const user_dir = "user";

// These are needed for userProgs.
const user_libs = &[_][]const u8{
    "ulib",
    "printf",
    "umalloc",
};

const usys_perl_file = "user/usys.pl";

// These depend on userLib.
const user_progs = &[_][]const u8{
    "cat",
    "echo",
    "forktest",
    "grep",
    "init",
    "kill",
    "ln",
    "ls",
    "mkdir",
    "rm",
    "sh",
    "stressfs",
    "usertests",
    "grind",
    "wc",
    "zombie",
};

const c_flags = &[_][]const u8{
    "-Wall",
    "-Werror",
    "-O",
    "-fno-omit-frame-pointer",
    "-ggdb",
    "-gdwarf-2",
    "-MD",
    "-mcmodel=medany",
    "-ffreestanding",
    "-fno-common",
    "-nostdlib",
    "-mno-relax",
    "-I.",
    "-fno-stack-protector",
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .whitelist = &[_]CrossTarget{riscv}, .default_target = riscv });

    // Generate the assembly for syscall entrypoints from user/usys.pl.
    const gen_usys_s = b.addSystemCommand(&[_][]const u8{"./user/usys.sh"});
    gen_usys_s.extra_file_dependencies = &[_][]const u8{ "user/usys.pl", "user/usys.sh" };
    b.default_step.dependOn(&gen_usys_s.step);

    // Build the user programs.
    inline for (user_progs) |prog_file| {
        const user_program_step = b.addExecutable(.{
            .name = "_" ++ prog_file,
            .root_source_file = null,
            .target = target,
        });
        const bin_path = user_program_step.getEmittedBin();

        user_program_step.addCSourceFile(.{ .file = .{ .path = user_dir ++ "/" ++ prog_file ++ ".c" }, .flags = c_flags });

        // Add the syscall entry assembly file.
        user_program_step.addAssemblyFile(.{ .path = "user/usys.S" });

        // Add the rest of the lib files.
        inline for (user_libs) |lib_file| {
            user_program_step.addCSourceFile(.{ .file = .{ .path = user_dir ++ "/" ++ lib_file ++ ".c" }, .flags = c_flags });
        }

        user_program_step.setLinkerScriptPath(.{ .path = "user/user.ld" });
        // b.installArtifact(user_program_step);
        b.getInstallStep().dependOn(&b.addInstallFile(bin_path, user_dir ++ "/_" ++ prog_file).step);
        b.default_step.dependOn(&user_program_step.step);
    }

    // // TODO(arjun): Use this so that the release mode can be passed in using the cli.
    // _ = b.standardReleaseOptions();

    // const exee = b.addExecutable("example", null);
    // exee.addCSourceFile("main.c", &[_][]const u8{});
    // exee.addCSourceFile("buffer.c", &[_][]const u8{});

    // // Standard optimization options allow the person running `zig build` to select
    // // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // // set a preferred release mode, allowing the user to decide how to optimize.
    // const optimize = b.standardOptimizeOption(.{});

    // const lib = b.addStaticLibrary(.{
    //     .name = "zwix",
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = .{ .path = "src/root.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });

    // // This declares intent for the library to be installed into the standard
    // // location when the user invokes the "install" step (the default step when
    // // running `zig build`).
    // b.installArtifact(lib);

    // const exe = b.addExecutable(.{
    //     .name = "zwix",
    //     .root_source_file = .{ .path = "src/main.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });

    // // This declares intent for the executable to be installed into the
    // // standard location when the user invokes the "install" step (the default
    // // step when running `zig build`).
    // b.installArtifact(exe);

    // // This *creates* a Run step in the build graph, to be executed when another
    // // step is evaluated that depends on it. The next line below will establish
    // // such a dependency.
    // const run_cmd = b.addRunArtifact(exe);

    // // By making the run step depend on the install step, it will be run from the
    // // installation directory rather than directly from within the cache directory.
    // // This is not necessary, however, if the application depends on other installed
    // // files, this ensures they will be present and in the expected location.
    // run_cmd.step.dependOn(b.getInstallStep());

    // // This allows the user to pass arguments to the application in the build
    // // command itself, like this: `zig build run -- arg1 arg2 etc`
    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    // // This creates a build step. It will be visible in the `zig build --help` menu,
    // // and can be selected like this: `zig build run`
    // // This will evaluate the `run` step rather than the default, which is "install".
    // const run_step = b.step("run", "Run the app");
    // run_step.dependOn(&run_cmd.step);

    // // Creates a step for unit testing. This only builds the test executable
    // // but does not run it.
    // const lib_unit_tests = b.addTest(.{
    //     .root_source_file = .{ .path = "src/root.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });

    // const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // const exe_unit_tests = b.addTest(.{
    //     .root_source_file = .{ .path = "src/main.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });

    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // // Similar to creating the run step earlier, this exposes a `test` step to
    // // the `zig build --help` menu, providing a way for the user to request
    // // running the unit tests.
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_lib_unit_tests.step);
    // test_step.dependOn(&run_exe_unit_tests.step);
}
