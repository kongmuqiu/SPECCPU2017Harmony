#!/bin/bash
set -e -x

SYSROOT=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/sysroot
OHOS_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/aarch64-linux-ohos
FLANG_DIR=/mnt/d/GitHub/SPECCPU2017Harmony225/flang
RT_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
SRC=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/src/main/cpp/503.bwaves_r

cd "$SRC"

flang-new-20 \
  --target=aarch64-linux-ohos \
  --sysroot="$SYSROOT" \
  -fuse-ld=lld \
  -shared -fPIC \
  -w -DSPEC_AUTO_SUPPRESS_OPENMP \
  -march=armv8.2-a+dotprod+fp16 -O3 -funroll-loops \
  -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 \
  -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE \
  -nostdlib \
  -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
  -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
  -L "$RT_LIB" -lclang_rt.builtins \
  "$OHOS_LIB/libc++_static.a" \
  "$OHOS_LIB/libc++abi.a" \
  "$OHOS_LIB/libunwind.a" \
  block_solver.F flow_lam.F flux_lam.F jacobian_lam.F shell_lam.F fill1.F fill2.F \
  -o lib503.bwaves_r.so

echo "=== OK: lib503.bwaves_r.so ==="
ls -la lib503.bwaves_r.so
file lib503.bwaves_r.so
llvm-readelf-20 -d lib503.bwaves_r.so | grep NEEDED
echo "=== Undefined symbols ==="
llvm-nm-20 -D --undefined-only lib503.bwaves_r.so

BASE=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/build/default/intermediates
cp lib503.bwaves_r.so "$BASE/cmake/default/obj/arm64-v8a/"
cp lib503.bwaves_r.so "$BASE/libs/default/arm64-v8a/"
cp lib503.bwaves_r.so "$BASE/stripped_native_libs/default/arm64-v8a/"
echo "=== Copied to all 3 build dirs ==="
