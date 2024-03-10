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

    var user_exec_paths = std.ArrayList([]const u8).init(b.allocator);
    defer user_exec_paths.deinit();
    var user_install_steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    defer user_install_steps.deinit();

    // Build the user programs.
    inline for (user_progs) |prog_file| {
        const user_program_step = b.addExecutable(.{
            .name = "_" ++ prog_file,
            .root_source_file = null,
            .target = target,
        });
        user_program_step.link_z_max_page_size = 4096;
        const bin_path = user_program_step.getEmittedBin();

        user_program_step.addCSourceFile(.{ .file = .{ .path = user_dir ++ "/" ++ prog_file ++ ".c" }, .flags = c_flags });

        // Add the syscall entry assembly file.
        user_program_step.addAssemblyFile(.{ .path = "user/usys.S" });

        // Add the rest of the lib files.
        inline for (user_libs) |lib_file| {
            user_program_step.addCSourceFile(.{ .file = .{ .path = user_dir ++ "/" ++ lib_file ++ ".c" }, .flags = c_flags });
        }

        user_program_step.setLinkerScriptPath(.{ .path = "user/user.ld" });
        const exec_path = user_dir ++ "/_" ++ prog_file;
        user_exec_paths.append(exec_path) catch unreachable;
        const install_user_exec_step = &b.addInstallFile(bin_path, exec_path).step;
        user_install_steps.append(install_user_exec_step) catch unreachable;
        b.getInstallStep().dependOn(install_user_exec_step);
        b.default_step.dependOn(&user_program_step.step);
    }

    // Build mkfs. Not RISCV target.
    const mkfs_program_step = b.addExecutable(.{
        .name = "mkfs",
        .root_source_file = null,
        .target = b.host,
    });
    const mkfs_bin_path = mkfs_program_step.getEmittedBin();
    const mkfs_c_flags = &[_][]const u8{
        "-Wall",
        "-Werror",
        "-I.",
    };
    mkfs_program_step.linkLibC();
    mkfs_program_step.addCSourceFile(.{ .file = .{ .path = "mkfs/mkfs.c" }, .flags = mkfs_c_flags });
    b.getInstallStep().dependOn(&b.addInstallFile(mkfs_bin_path, "mkfs/mkfs").step);
    // b.default_step.dependOn(&mkfs_program_step.step);

    const run_mkfs = b.addRunArtifact(mkfs_program_step);
    run_mkfs.addArg("fs.img");
    run_mkfs.addArg("README");

    // Wait for the user installation to finish.
    for (user_install_steps.items) |item| {
        run_mkfs.step.dependOn(item);
    }

    var fs_img_args = std.ArrayList([]const u8).init(b.allocator);
    defer fs_img_args.deinit();

    inline for (user_progs) |file| {
        run_mkfs.addArg("zig-out/" ++ "user/_" ++ file);
    }
    b.default_step.dependOn(&run_mkfs.step);

    // var fs_img_args = std.ArrayList([]const u8).init(b.allocator);
    // defer fs_img_args.deinit();

    // fs_img_args.append("fs.img") catch unreachable;
    // fs_img_args.append("README") catch unreachable;

    // inline for (user_progs) |file| {
    //     fs_img_args.append("zig-out/" ++ "user/_" ++ file) catch unreachable;
    // }

    // const fs_img_args_slice = fs_img_args.toOwnedSlice() catch unreachable;
    // const fs_img_step = b.addSystemCommand(fs_img_args_slice);
    // fs_img_step.extra_file_dependencies = fs_img_args_slice;
    // fs_img_step.step.dependOn(&mkfs_program_step.step);
    // b.default_step.dependOn(&fs_img_step.step);

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
