# =============================================================================
# spec_flags.cmake — SPEC CPU 2017 Central Optimization Configuration
# =============================================================================
# Single source of truth for all benchmark compilation flags.
# Modify variables here to change optimization for ALL benchmarks uniformly.
#
# Test fairness: all benchmarks share identical base flags from this file.
# Controllability: toggle LTO, math relaxation, march, etc. in one place.
#
# NOTE: All multi-value variables use CMake lists (no quotes) so that
#       target_compile_options() passes each flag as a separate argument.
# =============================================================================

# --- Architecture Target ---
# Kirin 9030: Cortex-A520 (0xd24, little) + Cortex-A720 (0xd47, big) + X925 (0xd06, super)
# armv8.2-a : baseline ISA for all cores (atomics, LSE)
# +sve       : Scalable Vector Extension (DISABLED — testing without SVE)
# +dotprod   : INT8 dot product (SDOT/UDOT, confirmed by asimddp feature)
# +fp16      : Half-precision FP (confirmed by fphp/asimdhp feature)
set(SPEC_MARCH -march=armv8.2-a+dotprod+fp16)

# --- Optimization Level ---
set(SPEC_OPT -O3 -funroll-loops)

# --- SPEC Platform Defines (required by all benchmarks) ---
set(SPEC_DEFS -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE)

# --- Combined base flags (arch + opt + defines) ---
set(SPEC_BASE ${SPEC_MARCH} ${SPEC_OPT} ${SPEC_DEFS})

# --- LTO Variants ---
# FULL : best for most benchmarks
# THIN : lighter alternative for benchmarks where full LTO causes ICE/slow/miscompile
# (none): for benchmarks where ANY LTO causes miscompilation (e.g. 502.gcc_r)
# DISABLED — testing without LTO
set(SPEC_LTO      )
set(SPEC_LTO_THIN )

# --- Math Relaxation Flags (C/C++ ONLY — flang does not support these) ---
# BASIC: safe errno/trap removal, suitable for most benchmarks
set(SPEC_MATH_BASIC -fno-math-errno -fno-trapping-math)
# AGGRESSIVE: also allows finite-only, no-signed-zeros, reciprocal-math
# Only for FP benchmarks whose validation tolerances explicitly allow it
set(SPEC_MATH_AGGR ${SPEC_MATH_BASIC} -ffinite-math-only -fno-signed-zeros -freciprocal-math)

# --- C/C++ Compatibility (not for pure-Fortran targets) ---
set(SPEC_CC_VIS    -fvisibility=protected)
set(SPEC_CC_WARN   -Wno-error=format-security -Wno-error=reserved-user-defined-literal)
set(SPEC_CC_COMPAT -fcommon)

# --- Fortran LLVM Tuning (for 548.exchange2_r) ---
set(SPEC_FLANG_INT_TUNE -fwrapv -mllvm -unroll-threshold=200 -mllvm -inline-threshold=500)
