#!/bin/bash
set -e -x
SRC=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/src/main/cpp/548.exchange2_r/lib548.exchange2_r.so
BASE=/mnt/d/GitHub/SPECCPU2017Harmony225/entry/build/default/intermediates

cp "$SRC" "$BASE/cmake/default/obj/arm64-v8a/"
cp "$SRC" "$BASE/libs/default/arm64-v8a/"
cp "$SRC" "$BASE/stripped_native_libs/default/arm64-v8a/"

echo "=== Copied lib548.exchange2_r.so to all 3 directories ==="
ls -la "$BASE/cmake/default/obj/arm64-v8a/lib548"*
ls -la "$BASE/libs/default/arm64-v8a/lib548"*
ls -la "$BASE/stripped_native_libs/default/arm64-v8a/lib548"*
