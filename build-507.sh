#!/bin/bash
set -e -x

SYSROOT=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/sysroot
OHOS_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/aarch64-linux-ohos
OHOS_CXX=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/include/libcxx-ohos/include/c++/v1
FLANG_DIR=/mnt/d/GitHub/SPECCPU2017Harmony225/flang
RT_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
SRC=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/src/main/cpp/507.cactuBSSN_r

cd "$SRC"
rm -rf _mod _obj
mkdir -p _mod _obj

TARGET="--target=aarch64-linux-ohos --sysroot=$SYSROOT"
SPEC="-march=armv8.2-a+dotprod+fp16 -O3 -funroll-loops -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE"

CFLAGS="$TARGET -fPIC -Iinclude -DCCODE -fvisibility=protected -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC"
CXXFLAGS="$TARGET -fPIC -nostdinc++ -isystem $OHOS_CXX -Iinclude -DCCODE -DCCTK_DISABLE_RESTRICT=1 -fvisibility=protected -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC"
FFLAGS="$TARGET -fPIC -Iinclude -DFCODE -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC -module-dir _mod -I _mod"

# Parse file list from CMakeLists.txt (single long line)
ALLFILES=$(grep 'add_library(507' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')

objname() {
  echo "_obj/$(echo "$1" | tr '/' '_' | sed 's/\.[^.]*$/.o/')"
}

# Compile C files
echo "=== Compiling C files ==="
C_COUNT=0
for f in $ALLFILES; do
  case "$f" in *.c) ;; *) continue ;; esac
  obj=$(objname "$f")
  clang $CFLAGS -c "$f" -o "$obj"
  C_COUNT=$((C_COUNT+1))
done
echo "=== Compiled $C_COUNT C files ==="

# Compile C++ files
echo "=== Compiling C++ files ==="
CXX_COUNT=0
for f in $ALLFILES; do
  case "$f" in *.cc) ;; *) continue ;; esac
  obj=$(objname "$f")
  clang++ $CXXFLAGS -c "$f" -o "$obj"
  CXX_COUNT=$((CXX_COUNT+1))
done
echo "=== Compiled $CXX_COUNT C++ files ==="

# Compile Fortran files (multi-pass for module deps)
echo "=== Compiling Fortran files ==="
F_FILES=()
for f in $ALLFILES; do
  case "$f" in *.f90|*.F90|*.F) F_FILES+=("$f") ;; esac
done

REMAINING=("${F_FILES[@]}")
PASS=0
F_COMPILED=0
while [ ${#REMAINING[@]} -gt 0 ]; do
  PASS=$((PASS+1))
  FAILED=()
  for f in "${REMAINING[@]}"; do
    obj=$(objname "$f")
    if flang-new-20 $FFLAGS -c "$f" -o "$obj" 2>/dev/null; then
      F_COMPILED=$((F_COMPILED+1))
      echo "  [pass $PASS] ($F_COMPILED/${#F_FILES[@]}) $f"
    else
      FAILED+=("$f")
    fi
  done
  echo "=== Pass $PASS done: remaining ${#FAILED[@]} ==="
  if [ ${#FAILED[@]} -gt 0 ] && [ ${#FAILED[@]} -eq ${#REMAINING[@]} ]; then
    echo "ERROR: No progress. Showing error for ${FAILED[0]}:"
    flang-new-20 $FFLAGS -c "${FAILED[0]}" -o "_obj/_test.o" || true
    exit 1
  fi
  REMAINING=("${FAILED[@]}")
done
echo "=== All Fortran files compiled in $PASS passes ==="

# Link
echo "=== Linking ==="
flang-new-20 $TARGET -fuse-ld=lld -shared -nostdlib \
  _obj/*.o \
  -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
  -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
  -L "$RT_LIB" -lclang_rt.builtins \
  "$OHOS_LIB/libc++_static.a" \
  "$OHOS_LIB/libc++abi.a" \
  "$OHOS_LIB/libunwind.a" \
  -o lib507.cactuBSSN_r.so

echo "=== OK: lib507.cactuBSSN_r.so ==="
ls -la lib507.cactuBSSN_r.so
file lib507.cactuBSSN_r.so
llvm-readelf-20 -d lib507.cactuBSSN_r.so | grep NEEDED
echo "=== Undefined symbols ==="
llvm-nm-20 -D --undefined-only lib507.cactuBSSN_r.so

BASE=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/build/default/intermediates
cp lib507.cactuBSSN_r.so "$BASE/cmake/default/obj/arm64-v8a/"
cp lib507.cactuBSSN_r.so "$BASE/libs/default/arm64-v8a/"
cp lib507.cactuBSSN_r.so "$BASE/stripped_native_libs/default/arm64-v8a/"
echo "=== Copied to all 3 build dirs ==="
