#!/bin/bash
set -e -x

PROJ=/mnt/d/GitHub/SPECCPU2017Harmony225
TC=$PROJ/ohos-toolchain.cmake
DST=$PROJ/flang
LLVM=$HOME/llvm-project
SYSROOT=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/sysroot
OHOS_CXX=/mnt/c/Users/25444/AppData/Local/OpenHarmony/Sdk/12/native/llvm/include/c++/v1
CFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -nostdinc++ -isystem $OHOS_CXX -DFLANG_LITTLE_ENDIAN=1 -fPIC -O3"

mkdir -p "$DST"

# 1. libunwind (skip if already built)
if [ ! -f "$DST/libunwind.a" ]; then
  cd "$LLVM/libunwind"
  rm -rf build && mkdir build && cd build
  cmake .. -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TC" -DLIBUNWIND_ENABLE_SHARED=OFF
  ninja
  cp lib/libunwind.a "$DST/"
  echo "=== OK: libunwind.a ==="
else
  echo "=== SKIP: libunwind.a (already exists) ==="
fi

# 2. libFortranDecimal (manual compile)
cd "$LLVM/flang/lib/Decimal"
rm -rf build && mkdir build
for f in *.cpp; do
  clang++ $CFLAGS -std=c++17 \
    -I "$LLVM/flang/include" \
    -I "$LLVM/flang/lib/Decimal" \
    -c "$f" -o "build/${f%.cpp}.o"
  echo "  compiled $f"
done
llvm-ar-20 rcs "$DST/libFortranDecimal.a" build/*.o
echo "=== OK: libFortranDecimal.a ==="

# 3. libFortranRuntime (manual compile)
cd "$LLVM/flang/runtime"
rm -rf build && mkdir build
for f in *.cpp; do
  clang++ $CFLAGS -std=c++17 \
    -I "$LLVM/flang/include" \
    -I "$LLVM/flang/runtime" \
    -I "$LLVM/llvm/include" \
    -c "$f" -o "build/${f%.cpp}.o"
  echo "  compiled $f"
done
llvm-ar-20 rcs "$DST/libFortranRuntime.a" build/*.o
echo "=== OK: libFortranRuntime.a ==="

echo ""
echo "=== All done ==="
ls -la "$DST"
