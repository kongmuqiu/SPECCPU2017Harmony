#!/bin/bash
set -e -x

SYSROOT=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/sysroot
OHOS_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/aarch64-linux-ohos
FLANG_DIR=/mnt/d/GitHub/SPECCPU2017Harmony225/flang
RT_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
SRC=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/src/main/cpp/548.exchange2_r

cd "$SRC"

flang-new-20 \
  --target=aarch64-linux-ohos \
  --sysroot="$SYSROOT" \
  -fuse-ld=lld \
  -shared -fPIC \
  -DSPEC_AUTO_SUPPRESS_OPENMP \
  -march=armv8.2-a+dotprod+fp16 -O3 -funroll-loops -fwrapv \
  -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 \
  -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE \
  -nostdlib \
  -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
  -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
  -L "$RT_LIB" -lclang_rt.builtins \
  "$OHOS_LIB/libc++_static.a" \
  "$OHOS_LIB/libc++abi.a" \
  "$OHOS_LIB/libunwind.a" \
  exchange2.F90 \
  -o lib548.exchange2_r.so

echo "=== OK: lib548.exchange2_r.so ==="
ls -la lib548.exchange2_r.so
file lib548.exchange2_r.so

# Check NEEDED
llvm-readelf-20 -d lib548.exchange2_r.so | grep NEEDED

# Check undefined symbols
echo "=== Undefined symbols ==="
llvm-nm-20 -D --undefined-only lib548.exchange2_r.so

# Copy to build dirs
BASE=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/build/default/intermediates
cp lib548.exchange2_r.so "$BASE/cmake/default/obj/arm64-v8a/"
cp lib548.exchange2_r.so "$BASE/libs/default/arm64-v8a/"
cp lib548.exchange2_r.so "$BASE/stripped_native_libs/default/arm64-v8a/"
echo "=== Copied to all 3 build dirs ==="
