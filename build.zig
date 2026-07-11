const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gpu_enabled = b.option(bool, "gpu", "Enable GPU/CUDA via Futhark CUDA backend") orelse false;
    const zk_enabled = b.option(bool, "zk", "Compile Circom ZK circuits") orelse false;
    const verify_enabled = b.option(bool, "verify", "Run Lean verification") orelse false;
    const rtl_enabled = b.option(bool, "rtl", "Compile Haskell RTL simulation") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "gpu_acceleration", gpu_enabled);
    build_options.addOption(bool, "zk_enabled", zk_enabled);
    build_options.addOption(bool, "verify_enabled", verify_enabled);
    build_options.addOption(bool, "rtl_enabled", rtl_enabled);

    const futhark_c = b.path("src/hw/accel/futhark_kernels.c");
    const futhark_gpu_c = b.path("src/hw/accel/main_gpu.c");
    const futhark_include = b.path("src/hw/accel");

    const futhark_cpu_step = b.addSystemCommand(&.{
        "futhark", "c", "--library",
        "src/hw/accel/futhark_kernels.fut",
        "-o", "src/hw/accel/futhark_kernels",
    });

    const futhark_gpu_step = b.addSystemCommand(&.{
        "futhark", "opencl", "--library",
        "src/hw/accel/main.fut",
        "-o", "src/hw/accel/main_gpu",
    });

    const core_relational_mod = b.createModule(.{
        .root_source_file = b.path("src/core_relational/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const inference_server_exe = b.addExecutable(.{
        .name = "jaide-inference-server",
        .root_source_file = b.path("src/inference_server_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    inference_server_exe.linkLibC();
    inference_server_exe.addCSourceFile(.{ .file = futhark_c, .flags = &.{"-O2"} });
    inference_server_exe.addIncludePath(futhark_include);
    inference_server_exe.root_module.addOptions("build_options", build_options);
    inference_server_exe.root_module.addImport("core_relational", core_relational_mod);
    inference_server_exe.step.dependOn(&futhark_cpu_step.step);
    b.installArtifact(inference_server_exe);

    if (gpu_enabled) {
        const distributed_futhark_exe = b.addExecutable(.{
            .name = "jaide-distributed-futhark",
            .root_source_file = b.path("src/main_distributed_futhark.zig"),
            .target = target,
            .optimize = optimize,
        });
        distributed_futhark_exe.linkLibC();
        distributed_futhark_exe.addCSourceFile(.{ .file = futhark_gpu_c, .flags = &.{"-O2"} });
        distributed_futhark_exe.addCSourceFile(.{ .file = futhark_c, .flags = &.{"-O2"} });
        distributed_futhark_exe.addIncludePath(futhark_include);
        distributed_futhark_exe.addIncludePath(.{ .cwd_relative = "/usr/local/cuda/include" });
        distributed_futhark_exe.addLibraryPath(.{ .cwd_relative = "/usr/local/cuda/lib64" });
        distributed_futhark_exe.addLibraryPath(.{ .cwd_relative = "/usr/local/cuda/lib64/stubs" });
        distributed_futhark_exe.linkSystemLibrary("cuda");
        distributed_futhark_exe.linkSystemLibrary("cudart");
        distributed_futhark_exe.linkSystemLibrary("nvrtc");
        distributed_futhark_exe.linkSystemLibrary("nccl");
        distributed_futhark_exe.root_module.addOptions("build_options", build_options);
        distributed_futhark_exe.root_module.addImport("core_relational", core_relational_mod);
        distributed_futhark_exe.step.dependOn(&futhark_cpu_step.step);
        distributed_futhark_exe.step.dependOn(&futhark_gpu_step.step);
        b.installArtifact(distributed_futhark_exe);

        const distributed_futhark_install = b.addInstallArtifact(distributed_futhark_exe, .{});
        const distributed_futhark_step = b.step("distributed-futhark", "Build only the Futhark-accelerated distributed trainer");
        distributed_futhark_step.dependOn(&distributed_futhark_install.step);
    }

    const tensor_tests = b.addTest(.{
        .root_source_file = b.path("src/core/tensor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tensor_tests = b.addRunArtifact(tensor_tests);
    const tensor_test_step = b.step("test-tensor", "Run tensor tests");
    tensor_test_step.dependOn(&run_tensor_tests.step);

    const memory_tests = b.addTest(.{
        .root_source_file = b.path("src/core/memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_memory_tests = b.addRunArtifact(memory_tests);
    const memory_test_step = b.step("test-memory", "Run memory tests");
    memory_test_step.dependOn(&run_memory_tests.step);

    const rsf_tests = b.addTest(.{
        .root_source_file = b.path("src/processor/rsf.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_rsf_tests = b.addRunArtifact(rsf_tests);
    const rsf_test_step = b.step("test-rsf", "Run RSF tests");
    rsf_test_step.dependOn(&run_rsf_tests.step);

    const oftb_tests = b.addTest(.{
        .root_source_file = b.path("src/processor/oftb.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_oftb_tests = b.addRunArtifact(oftb_tests);
    const oftb_test_step = b.step("test-oftb", "Run OFTB tests");
    oftb_test_step.dependOn(&run_oftb_tests.step);

    const embedding_tests = b.addTest(.{
        .root_source_file = b.path("src/core/learned_embedding.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_embedding_tests = b.addRunArtifact(embedding_tests);
    const embedding_test_step = b.step("test-embedding", "Run embedding tests");
    embedding_test_step.dependOn(&run_embedding_tests.step);

    const nsir_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/nsir_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_nsir_tests = b.addRunArtifact(nsir_tests);
    const nsir_test_step = b.step("test-nsir", "Run NSIR graph tests");
    nsir_test_step.dependOn(&run_nsir_tests.step);

    const reasoning_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/reasoning_orchestrator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_reasoning_tests = b.addRunArtifact(reasoning_tests);
    const reasoning_test_step = b.step("test-reasoning", "Run reasoning orchestrator tests");
    reasoning_test_step.dependOn(&run_reasoning_tests.step);

    const crev_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/crev_pipeline.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_crev_tests = b.addRunArtifact(crev_tests);
    const crev_test_step = b.step("test-crev", "Run CREV pipeline tests");
    crev_test_step.dependOn(&run_crev_tests.step);

    const surprise_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/surprise_memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_surprise_tests = b.addRunArtifact(surprise_tests);
    const surprise_test_step = b.step("test-surprise", "Run surprise memory tests");
    surprise_test_step.dependOn(&run_surprise_tests.step);

    const temporal_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/temporal_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_temporal_tests = b.addRunArtifact(temporal_tests);
    const temporal_test_step = b.step("test-temporal", "Run temporal graph tests");
    temporal_test_step.dependOn(&run_temporal_tests.step);

    const vpu_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/vpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_vpu_tests = b.addRunArtifact(vpu_tests);
    const vpu_test_step = b.step("test-vpu", "Run VPU tests");
    vpu_test_step.dependOn(&run_vpu_tests.step);

    const fnds_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/fnds.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_fnds_tests = b.addRunArtifact(fnds_tests);
    const fnds_test_step = b.step("test-fnds", "Run FNDS tests");
    fnds_test_step.dependOn(&run_fnds_tests.step);

    const formal_verification_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/formal_verification.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_formal_verification_tests = b.addRunArtifact(formal_verification_tests);
    const formal_verification_test_step = b.step("test-formal", "Run formal verification tests");
    formal_verification_test_step.dependOn(&run_formal_verification_tests.step);

    const security_proofs_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/security_proofs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_security_proofs_tests = b.addRunArtifact(security_proofs_tests);
    const security_proofs_test_step = b.step("test-security", "Run security proofs tests");
    security_proofs_test_step.dependOn(&run_security_proofs_tests.step);

    const quantum_task_adapter_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/quantum_task_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_quantum_task_adapter_tests = b.addRunArtifact(quantum_task_adapter_tests);
    const quantum_task_adapter_test_step = b.step("test-quantum-adapter", "Run quantum task adapter tests");
    quantum_task_adapter_test_step.dependOn(&run_quantum_task_adapter_tests.step);

    const signal_propagation_tests = b.addTest(.{
        .root_source_file = b.path("src/core_relational/signal_propagation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_signal_propagation_tests = b.addRunArtifact(signal_propagation_tests);
    const signal_propagation_test_step = b.step("test-signal", "Run signal propagation tests");
    signal_propagation_test_step.dependOn(&run_signal_propagation_tests.step);

    const stress_test = b.addTest(.{
        .name = "stress-refcount",
        .root_source_file = b.path("src/tests/stress_tensor_refcount.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stress_run = b.addRunArtifact(stress_test);
    const stress_step = b.step("stress-refcount", "Run tensor refcount stress test");
    stress_step.dependOn(&stress_run.step);

    const c_api_test = b.addExecutable(.{
        .name = "jaide-c-api-test",
        .target = target,
        .optimize = optimize,
    });
    c_api_test.addCSourceFile(.{ .file = b.path("src/tests/c_api_test.c"), .flags = &.{"-O2"} });
    c_api_test.addIncludePath(b.path("src/core_relational"));
    c_api_test.linkLibC();
    b.installArtifact(c_api_test);
    const c_api_test_run = b.addRunArtifact(c_api_test);
    const c_api_test_step = b.step("test-c-api", "Run C API test");
    c_api_test_step.dependOn(&c_api_test_run.step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_tensor_tests.step);
    test_all_step.dependOn(&run_memory_tests.step);
    test_all_step.dependOn(&run_rsf_tests.step);
    test_all_step.dependOn(&run_oftb_tests.step);
    test_all_step.dependOn(&run_embedding_tests.step);
    test_all_step.dependOn(&run_nsir_tests.step);
    test_all_step.dependOn(&run_reasoning_tests.step);
    test_all_step.dependOn(&run_crev_tests.step);
    test_all_step.dependOn(&run_surprise_tests.step);
    test_all_step.dependOn(&run_temporal_tests.step);
    test_all_step.dependOn(&run_vpu_tests.step);
    test_all_step.dependOn(&run_fnds_tests.step);
    test_all_step.dependOn(&run_formal_verification_tests.step);
    test_all_step.dependOn(&run_security_proofs_tests.step);
    test_all_step.dependOn(&run_quantum_task_adapter_tests.step);
    test_all_step.dependOn(&run_signal_propagation_tests.step);
    test_all_step.dependOn(&stress_run.step);
    test_all_step.dependOn(&c_api_test_run.step);

    if (zk_enabled) {
        const circom_step = b.addSystemCommand(&.{
            "circom", "src/zk/inference_trace.circom",
            "--r1cs", "--wasm", "--sym", "-o", "src/zk/",
        });
        const snarkjs_setup = b.addSystemCommand(&.{
            "snarkjs", "groth16", "setup",
            "src/zk/inference_trace.r1cs", "pot12_final.ptau",
            "src/zk/inference_trace.zkey",
        });
        snarkjs_setup.step.dependOn(&circom_step.step);
        const snarkjs_vkey = b.addSystemCommand(&.{
            "snarkjs", "zkey", "export", "verificationkey",
            "src/zk/inference_trace.zkey",
            "src/zk/verification_key.json",
        });
        snarkjs_vkey.step.dependOn(&snarkjs_setup.step);
        const zk_step = b.step("zk", "Compile ZK circuits");
        zk_step.dependOn(&snarkjs_vkey.step);
    }

    if (verify_enabled) {
        const lean_step = b.addSystemCommand(&.{ "lake", "build" });
        lean_step.setCwd(b.path("src/verification"));
        const verify_step = b.step("verify", "Run Lean formal verification");
        verify_step.dependOn(&lean_step.step);
        test_all_step.dependOn(&lean_step.step);
    }

    if (rtl_enabled) {
        const ghc_step = b.addSystemCommand(&.{
            "ghc", "-O2", "-dynamic", "-shared", "-fPIC",
            "src/hw/rtl/MemoryArbiter.hs",
            "src/hw/rtl/RankerCore.hs",
            "src/hw/rtl/SSISearch.hs",
            "-o", "src/hw/rtl/librtl_sim.so",
        });
        const rtl_exe = b.addExecutable(.{
            .name = "jaide-rtl-sim",
            .root_source_file = b.path("src/hw/rtl/rtl_sim_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        rtl_exe.linkLibC();
        rtl_exe.step.dependOn(&ghc_step.step);
        b.installArtifact(rtl_exe);
        const rtl_install = b.addInstallArtifact(rtl_exe, .{});
        const rtl_step = b.step("rtl", "Build Haskell RTL simulation");
        rtl_step.dependOn(&rtl_install.step);
    }

    const bench_deps = b.createModule(.{
        .root_source_file = b.path("src/_bench_deps.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_deps.addOptions("build_options", build_options);

    const bench_step = b.step("bench", "Run all benchmarks");

    const bench_sources = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "bench-rsf", .path = "src/tests/bench_rsf.zig" },
        .{ .name = "bench-matmul", .path = "src/tests/bench_matmul.zig" },
        .{ .name = "bench-tensor-ops", .path = "src/tests/bench_tensor_ops.zig" },
        .{ .name = "bench-sfd", .path = "src/tests/bench_sfd.zig" },
    };

    inline for (bench_sources) |src| {
        const exe = b.addExecutable(.{
            .name = src.name,
            .root_source_file = b.path(src.path),
            .target = target,
            .optimize = optimize,
        });
        exe.linkLibC();
        exe.addCSourceFile(.{ .file = futhark_c, .flags = &.{"-O2"} });
        exe.addIncludePath(futhark_include);
        exe.root_module.addOptions("build_options", build_options);
        exe.root_module.addImport("deps", bench_deps);
        exe.step.dependOn(&futhark_cpu_step.step);
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        bench_step.dependOn(&run.step);
    }
}
