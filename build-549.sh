#!/bin/bash
set -e -x

SYSROOT=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/sysroot
OHOS_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/aarch64-linux-ohos
FLANG_DIR=/mnt/d/GitHub/SPECCPU2017Harmony225/flang
RT_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
SRC=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/src/main/cpp/549.fotonik3d_r

cd "$SRC"
rm -rf _mod _obj
mkdir -p _mod _obj

FFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -fPIC \
  -I. -DSPEC_AUTO_SUPPRESS_OPENMP \
  -march=armv8.2-a+dotprod+fp16 -O3 -funroll-loops \
  -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 \
  -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE \
  -module-dir _mod -I _mod"

# Compile in dependency order (modules first)
FILES=(
  parameter.f90
  globalvar.F90
  MPI_dummy.F90
  readline.f90
  timerRoutine.f90
  communicate.F90
  power.F90
  calcflops.F90
  material.F90
  mur.F90
  PlaneSource.F90
  PEC.F90
  UPML.F90
  huygens.F90
  update.F90
  writeout.F90
  init.F90
  leapfrog.F90
  yeemain.F90
)

for f in "${FILES[@]}"; do
  flang-new-20 $FFLAGS -c "$f" -o "_obj/${f%.*}.o"
  echo "  compiled $f"
done

echo "=== Linking ==="
flang-new-20 \
  --target=aarch64-linux-ohos \
  --sysroot="$SYSROOT" \
  -fuse-ld=lld \
  -shared \
  -nostdlib \
  _obj/*.o \
  -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
  -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
  -L "$RT_LIB" -lclang_rt.builtins \
  "$OHOS_LIB/libc++_static.a" \
  "$OHOS_LIB/libc++abi.a" \
  "$OHOS_LIB/libunwind.a" \
  -o lib549.fotonik3d_r.so

echo "=== OK: lib549.fotonik3d_r.so ==="
ls -la lib549.fotonik3d_r.so
file lib549.fotonik3d_r.so
llvm-readelf-20 -d lib549.fotonik3d_r.so | grep NEEDED
echo "=== Undefined symbols ==="
llvm-nm-20 -D --undefined-only lib549.fotonik3d_r.so

BASE=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/build/default/intermediates
cp lib549.fotonik3d_r.so "$BASE/cmake/default/obj/arm64-v8a/"
cp lib549.fotonik3d_r.so "$BASE/libs/default/arm64-v8a/"
cp lib549.fotonik3d_r.so "$BASE/stripped_native_libs/default/arm64-v8a/"
echo "=== Copied to all 3 build dirs ==="
