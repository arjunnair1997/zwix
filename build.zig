const std = @import("std");

const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;

const riscv = CrossTarget{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    // Figure out how to set this to rv64g if necessary.
    .cpu_model = .determined_by_cpu_arch,
};

const user_dir = "user";
const kernel_dir = "kernel";

// These are needed for userProgs.
const user_libs = &[_][]const u8{
    "ulib",
    "printf",
    "umalloc",
};

const usys_perl_file = user_dir ++ "/" ++ "usys.pl";

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

const kernel_c_progs = &[_][]const u8{
    "start",
    "console",
    "printf",
    "uart",
    "kalloc",
    "spinlock",
    "string",
    "main",
    "vm",
    "proc",
    "trap",
    "syscall",
    "sysproc",
    "bio",
    "fs",
    "log",
    "sleeplock",
    "file",
    "pipe",
    "exec",
    "sysfile",
    "plic",
    "virtio_disk",
};

// entry must be first; we want it to be passed in as the first
// argument to the linker so that it is placed at 0x80000000.
const kernel_asm_progs = &[_][]const u8{
    "entry",
    "kernelvec",
    "swtch",
    "trampoline",
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
    //
    // TODO(arjun): Replace bash script with zig code.
    const gen_usys_s = b.addSystemCommand(&[_][]const u8{"./user/usys.sh"});
    gen_usys_s.extra_file_dependencies = &[_][]const u8{ user_dir ++ "/" ++ "usys.pl", user_dir ++ "/" ++ "usys.sh" };
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
        user_program_step.step.dependOn(&gen_usys_s.step);
        user_program_step.addAssemblyFile(.{ .path = user_dir ++ "/" ++ "usys.S" });

        // Add the rest of the lib files.
        inline for (user_libs) |lib_file| {
            user_program_step.addCSourceFile(.{ .file = .{ .path = user_dir ++ "/" ++ lib_file ++ ".c" }, .flags = c_flags });
        }

        user_program_step.setLinkerScriptPath(.{ .path = user_dir ++ "/" ++ "user.ld" });
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
        run_mkfs.addArg("zig-out/" ++ user_dir ++ "/" ++ "_" ++ file);
    }
    b.default_step.dependOn(&run_mkfs.step);

    // Build the kernel.
    const kernel_program_step = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = null,
        .target = target,
    });
    kernel_program_step.link_z_max_page_size = 4096;
    const kernel_bin_path = kernel_program_step.getEmittedBin();
    kernel_program_step.setLinkerScriptPath(.{ .path = kernel_dir ++ "/" ++ "kernel.ld" });

    // It is necessary that the asm_progs are added before, because we want entry to be placed
    // at 0x80000000.
    inline for (kernel_asm_progs) |prog_file| {
        kernel_program_step.addAssemblyFile(.{ .path = kernel_dir ++ "/" ++ prog_file ++ ".S" });
    }
    inline for (kernel_c_progs) |prog_file| {
        kernel_program_step.addCSourceFile(.{ .file = .{ .path = kernel_dir ++ "/" ++ prog_file ++ ".c" }, .flags = c_flags });
    }
    const exec_path = kernel_dir ++ "/kernel";
    const install_kernel_exec_step = &b.addInstallFile(kernel_bin_path, exec_path).step;
    b.getInstallStep().dependOn(install_kernel_exec_step);
    b.default_step.dependOn(&kernel_program_step.step);

    const cleanup_step = b.step("clean", "Remove build artifacts");
    cleanup_step.makeFn = deleteFiles;
}

fn deleteFiles(_: *std.Build.Step, _: *std.Progress.Node) !void {
    const cwd = std.fs.cwd();

    cwd.deleteTree("zig-cache") catch |err| {
        return err;
    };

    cwd.deleteTree("zig-out") catch |err| {
        return err;
    };
    cwd.deleteFile("fs.img") catch |err| {
        return err;
    };
}
