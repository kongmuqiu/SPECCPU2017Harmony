#!/bin/bash
# Build Fortran runtime libraries (libunwind, libFortranDecimal, libFortranRuntime)
# from LLVM source for OpenHarmony cross-compilation.
#
# Prerequisites:
#   - Clone llvm-project: git clone https://github.com/llvm/llvm-project.git
#   - Install flang-new-20 and lld-20 from https://apt.llvm.org/
#
# Required environment variables:
#   OHOS_SDK_NATIVE  - Path to OpenHarmony SDK native directory
#   LLVM_PROJECT     - Path to llvm-project clone (default: $HOME/llvm-project)
set -e -x

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$OHOS_SDK_NATIVE" ]; then
  echo "ERROR: OHOS_SDK_NATIVE is not set."
  echo "Set it to the OpenHarmony SDK native directory, e.g.:"
  echo "  export OHOS_SDK_NATIVE=/path/to/OpenHarmony/Sdk/12/native"
  exit 1
fi

LLVM_PROJECT="${LLVM_PROJECT:-$HOME/llvm-project}"
if [ ! -d "$LLVM_PROJECT" ]; then
  echo "ERROR: LLVM_PROJECT ($LLVM_PROJECT) does not exist."
  echo "Clone it: git clone https://github.com/llvm/llvm-project.git"
  exit 1
fi

TC="$PROJ_DIR/ohos-toolchain.cmake"
DST="$PROJ_DIR/flang"
SYSROOT="$OHOS_SDK_NATIVE/sysroot"

# Find C++ headers location (try multiple known paths)
OHOS_CXX=""
for candidate in \
  "$OHOS_SDK_NATIVE/llvm/include/libcxx-ohos/include/c++/v1" \
  "$OHOS_SDK_NATIVE/llvm/include/c++/v1"; do
  if [ -d "$candidate" ]; then
    OHOS_CXX="$candidate"
    break
  fi
done
if [ -z "$OHOS_CXX" ]; then
  echo "WARNING: Could not find libc++ headers under $OHOS_SDK_NATIVE/llvm/include/"
fi

CFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -fPIC -O3"
if [ -n "$OHOS_CXX" ]; then
  CFLAGS="$CFLAGS -nostdinc++ -isystem $OHOS_CXX"
fi
CFLAGS="$CFLAGS -DFLANG_LITTLE_ENDIAN=1"

mkdir -p "$DST"

# 1. libunwind (skip if already built)
if [ ! -f "$DST/libunwind.a" ]; then
  cd "$LLVM_PROJECT/libunwind"
  rm -rf build && mkdir build && cd build
  cmake .. -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TC" -DLIBUNWIND_ENABLE_SHARED=OFF
  ninja
  cp lib/libunwind.a "$DST/"
  echo "=== OK: libunwind.a ==="
else
  echo "=== SKIP: libunwind.a (already exists) ==="
fi

# 2. libFortranDecimal (manual compile)
cd "$LLVM_PROJECT/flang/lib/Decimal"
rm -rf build && mkdir build
for f in *.cpp; do
  clang++ $CFLAGS -std=c++17 \
    -I "$LLVM_PROJECT/flang/include" \
    -I "$LLVM_PROJECT/flang/lib/Decimal" \
    -c "$f" -o "build/${f%.cpp}.o"
  echo "  compiled $f"
done
llvm-ar-20 rcs "$DST/libFortranDecimal.a" build/*.o
echo "=== OK: libFortranDecimal.a ==="

# 3. libFortranRuntime (manual compile)
cd "$LLVM_PROJECT/flang/runtime"
rm -rf build && mkdir build
for f in *.cpp; do
  clang++ $CFLAGS -std=c++17 \
    -I "$LLVM_PROJECT/flang/include" \
    -I "$LLVM_PROJECT/flang/runtime" \
    -I "$LLVM_PROJECT/llvm/include" \
    -c "$f" -o "build/${f%.cpp}.o"
  echo "  compiled $f"
done
llvm-ar-20 rcs "$DST/libFortranRuntime.a" build/*.o
echo "=== OK: libFortranRuntime.a ==="

echo ""
echo "=== All done ==="
ls -la "$DST"
