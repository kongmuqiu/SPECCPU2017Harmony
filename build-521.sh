#!/bin/bash
set -e -x

SYSROOT=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/sysroot
OHOS_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/aarch64-linux-ohos
OHOS_CXX=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/include/c++/v1
FLANG_DIR=/mnt/d/GitHub/SPECCPU2017Harmony225/flang
RT_LIB=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
SRC=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/src/main/cpp/521.wrf_r

cd "$SRC"

TARGET="--target=aarch64-linux-ohos --sysroot=$SYSROOT"
SPEC="-march=armv8.2-a+dotprod+fp16 -O3 -funroll-loops -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE"

CFLAGS="$TARGET -fPIC -DSPEC_AUTO_BYTEORDER=0x12345678 -DSPEC_CASE_FLAG -fvisibility=protected -I. -I./netcdf/include -I./inc -DSTUBMPI -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC"
FFLAGS="$TARGET -fPIC -fconvert=big-endian -I. -I./inc -I./netcdf/include \
  -DDM_PARALLEL -DEM_CORE=1 -DNMM_CORE=0 -DNMM_MAX_DIM=2600 \
  -DCOAMPS_CORE=0 -DDA_CORE=0 -DEXP_CORE=0 \
  -DIWORDSIZE=4 -DDWORDSIZE=8 -DRWORDSIZE=4 -DLWORDSIZE=4 \
  -DNETCDF -DINTIO -DCONFIG_BUF_LEN=32768 -DMAX_DOMAINS_F=21 \
  -DNMM_NEST=0 -DMAX_HISTORY=25 \
  -DSTUBMPI -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC"

objname() {
  echo "$1/$(echo "$2" | tr '/' '_' | sed 's/\.[^.]*$/.o/')"
}

build_target() {
  local TARGET_NAME="$1"
  local LIB_NAME="$2"
  local ALLFILES="$3"
  local OBJDIR="_obj_${TARGET_NAME}"
  local MODDIR="_mod_${TARGET_NAME}"

  rm -rf "$OBJDIR" "$MODDIR"
  mkdir -p "$OBJDIR" "$MODDIR"

  local LOCAL_FFLAGS="$FFLAGS -module-dir $MODDIR -I $MODDIR"

  # Compile C files
  echo "=== [$TARGET_NAME] Compiling C files ==="
  local C_COUNT=0
  for f in $ALLFILES; do
    case "$f" in *.c) ;; *) continue ;; esac
    obj=$(objname "$OBJDIR" "$f")
    clang $CFLAGS -c "$f" -o "$obj"
    C_COUNT=$((C_COUNT+1))
  done
  echo "=== [$TARGET_NAME] Compiled $C_COUNT C files ==="

  # Compile Fortran files (multi-pass)
  echo "=== [$TARGET_NAME] Compiling Fortran files ==="
  local F_FILES=()
  for f in $ALLFILES; do
    case "$f" in *.f90|*.F90|*.F) F_FILES+=("$f") ;; esac
  done

  local REMAINING=("${F_FILES[@]}")
  local PASS=0
  local F_COMPILED=0
  while [ ${#REMAINING[@]} -gt 0 ]; do
    PASS=$((PASS+1))
    local FAILED=()
    for f in "${REMAINING[@]}"; do
      obj=$(objname "$OBJDIR" "$f")
      if flang-new-20 $LOCAL_FFLAGS -c "$f" -o "$obj" 2>/dev/null; then
        F_COMPILED=$((F_COMPILED+1))
        echo "  [pass $PASS] ($F_COMPILED/${#F_FILES[@]}) $f"
      else
        FAILED+=("$f")
      fi
    done
    echo "=== [$TARGET_NAME] Pass $PASS: remaining ${#FAILED[@]} ==="
    if [ ${#FAILED[@]} -gt 0 ] && [ ${#FAILED[@]} -eq ${#REMAINING[@]} ]; then
      echo "ERROR: No progress. Showing error for ${FAILED[0]}:"
      flang-new-20 $LOCAL_FFLAGS -c "${FAILED[0]}" -o "$OBJDIR/_test.o" || true
      exit 1
    fi
    REMAINING=("${FAILED[@]}")
  done
  echo "=== [$TARGET_NAME] All Fortran files compiled in $PASS passes ==="

  # Link
  echo "=== [$TARGET_NAME] Linking ==="
  flang-new-20 $TARGET -fuse-ld=lld -shared -nostdlib \
    "$OBJDIR"/*.o \
    -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
    -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
    -L "$RT_LIB" -lclang_rt.builtins \
    "$OHOS_LIB/libc++_static.a" \
    "$OHOS_LIB/libc++abi.a" \
    "$OHOS_LIB/libunwind.a" \
    -o "$LIB_NAME"

  echo "=== OK: $LIB_NAME ==="
  ls -la "$LIB_NAME"
  file "$LIB_NAME"
  llvm-readelf-20 -d "$LIB_NAME" | grep NEEDED
}

# Target 1: lib521.wrf_r.so
T1_FILES=$(grep 'add_library(521.wrf_r' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')
build_target "wrf" "lib521.wrf_r.so" "$T1_FILES"

# Target 2: libdiffwrf_521.so
T2_FILES=$(grep 'add_library(diffwrf_521' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')
build_target "diffwrf" "libdiffwrf_521.so" "$T2_FILES"

# Copy to build dirs
BASE=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/build/default/intermediates
for so in lib521.wrf_r.so libdiffwrf_521.so; do
  cp "$so" "$BASE/cmake/default/obj/arm64-v8a/"
  cp "$so" "$BASE/libs/default/arm64-v8a/"
  cp "$so" "$BASE/stripped_native_libs/default/arm64-v8a/"
done
echo "=== Copied both .so to all 3 build dirs ==="
