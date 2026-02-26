#!/bin/bash
# Unified Fortran benchmark build script for OpenHarmony cross-compilation.
#
# Usage:
#   ./build-fortran.sh <benchmark...>
#   ./build-fortran.sh all
#
# Examples:
#   ./build-fortran.sh 503              # build 503.bwaves_r only
#   ./build-fortran.sh 507 521          # build 507 and 521
#   ./build-fortran.sh all              # build all Fortran benchmarks
#
# Required environment variables:
#   OHOS_SDK_NATIVE  - Path to OpenHarmony SDK native directory
#                      e.g., /path/to/OpenHarmony/Sdk/12/native
#
# Optional environment variables:
#   FLANG_DIR        - Path to Fortran runtime libraries (default: ./flang)
#   COPY_TO_BUILD    - Set to 1 to copy .so to build intermediates (default: 0)
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Validate environment ---
if [ -z "$OHOS_SDK_NATIVE" ]; then
  echo "ERROR: OHOS_SDK_NATIVE is not set."
  echo "Set it to the OpenHarmony SDK native directory, e.g.:"
  echo "  export OHOS_SDK_NATIVE=/path/to/OpenHarmony/Sdk/12/native"
  exit 1
fi

SYSROOT="$OHOS_SDK_NATIVE/sysroot"
OHOS_LIB="$OHOS_SDK_NATIVE/llvm/lib/aarch64-linux-ohos"
OHOS_CXX="$OHOS_SDK_NATIVE/llvm/include/libcxx-ohos/include/c++/v1"
FLANG_DIR="${FLANG_DIR:-$PROJ_DIR/flang}"

# Find clang RT lib directory dynamically (handles different clang versions)
RT_LIB=$(find "$OHOS_SDK_NATIVE/llvm/lib/clang" -path "*/lib/aarch64-linux-ohos" -type d 2>/dev/null | head -1)
if [ -z "$RT_LIB" ]; then
  echo "ERROR: Cannot find clang RT lib under $OHOS_SDK_NATIVE/llvm/lib/clang/"
  exit 1
fi

SRC_BASE="$PROJ_DIR/entry/src/main/cpp"
TARGET_FLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT"
SPEC_FLAGS="-march=armv8.2-a+dotprod+fp16 -O3 -funroll-loops \
  -DSPEC -DSPEC_LP64 -DSPEC_LINUX -DSPEC_LINUX_AARCH64 \
  -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE -DSPEC_NO_ISFINITE"

# --- Common functions ---

objname() {
  echo "$1/$(echo "$2" | tr '/' '_' | sed 's/\.[^.]*$/.o/')"
}

link_shared() {
  local OUTPUT="$1"
  shift
  flang-new-20 $TARGET_FLAGS -fuse-ld=lld -shared -nostdlib \
    "$@" \
    -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
    -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
    -L "$RT_LIB" -lclang_rt.builtins \
    "$OHOS_LIB/libc++_static.a" \
    "$OHOS_LIB/libc++abi.a" \
    "$OHOS_LIB/libunwind.a" \
    -o "$OUTPUT"
}

verify_so() {
  local SO="$1"
  echo "=== OK: $SO ==="
  ls -la "$SO"
  file "$SO"
  llvm-readelf-20 -d "$SO" | grep NEEDED || true
  echo "=== Undefined symbols ==="
  llvm-nm-20 -D --undefined-only "$SO" || true
}

copy_to_build() {
  if [ "${COPY_TO_BUILD:-0}" != "1" ]; then return; fi
  local SO="$1"
  local BASE="$PROJ_DIR/entry/build/default/intermediates"
  for dir in "cmake/default/obj/arm64-v8a" "libs/default/arm64-v8a" "stripped_native_libs/default/arm64-v8a"; do
    mkdir -p "$BASE/$dir"
    cp "$SO" "$BASE/$dir/"
  done
  echo "=== Copied $(basename "$SO") to build dirs ==="
}

# Multi-pass Fortran compilation to resolve module dependencies.
# Returns when all files compile, or exits on no-progress.
compile_fortran_multipass() {
  local MODDIR="$1"
  local OBJDIR="$2"
  local FFLAGS_LOCAL="$3"
  shift 3
  local FILES=("$@")

  local REMAINING=("${FILES[@]}")
  local PASS=0
  local COMPILED=0
  local TOTAL=${#FILES[@]}
  local MAX_PASSES=30

  while [ ${#REMAINING[@]} -gt 0 ] && [ $PASS -lt $MAX_PASSES ]; do
    PASS=$((PASS+1))
    local FAILED=()
    for f in "${REMAINING[@]}"; do
      local obj=$(objname "$OBJDIR" "$f")
      if flang-new-20 $FFLAGS_LOCAL -c "$f" -o "$obj" 2>/dev/null; then
        COMPILED=$((COMPILED+1))
        echo "  [pass $PASS] ($COMPILED/$TOTAL) $f"
      else
        FAILED+=("$f")
      fi
    done
    echo "=== Pass $PASS: remaining ${#FAILED[@]} ==="
    if [ ${#FAILED[@]} -gt 0 ] && [ ${#FAILED[@]} -eq ${#REMAINING[@]} ]; then
      echo "ERROR: No progress in pass $PASS. Showing error for ${FAILED[0]}:"
      flang-new-20 $FFLAGS_LOCAL -c "${FAILED[0]}" -o "$OBJDIR/_test.o" || true
      exit 1
    fi
    REMAINING=("${FAILED[@]}")
  done
  echo "=== All $TOTAL Fortran files compiled in $PASS passes ==="
}

# Compile C files from a file list
compile_c_files() {
  local CFLAGS_LOCAL="$1"
  local OBJDIR="$2"
  shift 2
  local ALLFILES="$@"
  local COUNT=0
  for f in $ALLFILES; do
    case "$f" in *.c) ;; *) continue ;; esac
    local obj=$(objname "$OBJDIR" "$f")
    clang $CFLAGS_LOCAL -c "$f" -o "$obj"
    COUNT=$((COUNT+1))
  done
  echo "=== Compiled $COUNT C files ==="
}

# Compile C++ files from a file list
compile_cxx_files() {
  local CXXFLAGS_LOCAL="$1"
  local OBJDIR="$2"
  shift 2
  local ALLFILES="$@"
  local COUNT=0
  for f in $ALLFILES; do
    case "$f" in *.cc|*.cpp|*.cxx) ;; *) continue ;; esac
    local obj=$(objname "$OBJDIR" "$f")
    clang++ $CXXFLAGS_LOCAL -c "$f" -o "$obj"
    COUNT=$((COUNT+1))
  done
  echo "=== Compiled $COUNT C++ files ==="
}

# Extract Fortran files from a file list
extract_fortran_files() {
  local result=()
  for f in "$@"; do
    case "$f" in *.f90|*.F90|*.F) result+=("$f") ;; esac
  done
  echo "${result[@]}"
}

# --- Per-benchmark build functions ---

build_503() {
  echo "======== Building 503.bwaves_r ========"
  local SRC="$SRC_BASE/503.bwaves_r"
  cd "$SRC"

  local FFLAGS="$TARGET_FLAGS -fPIC -w -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS"
  flang-new-20 $FFLAGS \
    -fuse-ld=lld -shared -nostdlib \
    -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
    -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
    -L "$RT_LIB" -lclang_rt.builtins \
    "$OHOS_LIB/libc++_static.a" \
    "$OHOS_LIB/libc++abi.a" \
    "$OHOS_LIB/libunwind.a" \
    block_solver.F flow_lam.F flux_lam.F jacobian_lam.F shell_lam.F fill1.F fill2.F \
    -o lib503.bwaves_r.so

  verify_so lib503.bwaves_r.so
  copy_to_build "$SRC/lib503.bwaves_r.so"
}

build_507() {
  echo "======== Building 507.cactuBSSN_r ========"
  local SRC="$SRC_BASE/507.cactuBSSN_r"
  cd "$SRC"
  rm -rf _mod _obj && mkdir -p _mod _obj

  local CFLAGS="$TARGET_FLAGS -fPIC -Iinclude -DCCODE -fvisibility=protected -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS"
  local CXXFLAGS="$TARGET_FLAGS -fPIC -nostdinc++ -isystem $OHOS_CXX -Iinclude -DCCODE -DCCTK_DISABLE_RESTRICT=1 -fvisibility=protected -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS"
  local FFLAGS="$TARGET_FLAGS -fPIC -Iinclude -DFCODE -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS -module-dir _mod -I _mod"

  local ALLFILES=$(grep 'add_library(507' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')

  compile_c_files "$CFLAGS" "_obj" $ALLFILES
  compile_cxx_files "$CXXFLAGS" "_obj" $ALLFILES

  local F_FILES=($(extract_fortran_files $ALLFILES))
  compile_fortran_multipass "_mod" "_obj" "$FFLAGS" "${F_FILES[@]}"

  link_shared lib507.cactuBSSN_r.so _obj/*.o
  verify_so lib507.cactuBSSN_r.so
  copy_to_build "$SRC/lib507.cactuBSSN_r.so"
}

build_521() {
  echo "======== Building 521.wrf_r ========"
  local SRC="$SRC_BASE/521.wrf_r"
  cd "$SRC"

  local CFLAGS="$TARGET_FLAGS -fPIC -DSPEC_AUTO_BYTEORDER=0x12345678 -DSPEC_CASE_FLAG -fvisibility=protected -I. -I./netcdf/include -I./inc -DSTUBMPI -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS"
  local FFLAGS="$TARGET_FLAGS -fPIC -fconvert=big-endian -I. -I./inc -I./netcdf/include \
    -DDM_PARALLEL -DEM_CORE=1 -DNMM_CORE=0 -DNMM_MAX_DIM=2600 \
    -DCOAMPS_CORE=0 -DDA_CORE=0 -DEXP_CORE=0 \
    -DIWORDSIZE=4 -DDWORDSIZE=8 -DRWORDSIZE=4 -DLWORDSIZE=4 \
    -DNETCDF -DINTIO -DCONFIG_BUF_LEN=32768 -DMAX_DOMAINS_F=21 \
    -DNMM_NEST=0 -DMAX_HISTORY=25 \
    -DSTUBMPI -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS"

  # Target 1: lib521.wrf_r.so
  local T1_FILES=$(grep 'add_library(521.wrf_r' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')
  _build_mixed_target "wrf" "lib521.wrf_r.so" "$CFLAGS" "$FFLAGS" "$T1_FILES"

  # Target 2: libdiffwrf_521.so
  local T2_FILES=$(grep 'add_library(diffwrf_521' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')
  _build_mixed_target "diffwrf" "libdiffwrf_521.so" "$CFLAGS" "$FFLAGS" "$T2_FILES"

  copy_to_build "$SRC/lib521.wrf_r.so"
  copy_to_build "$SRC/libdiffwrf_521.so"
}

build_527() {
  echo "======== Building 527.cam4_r ========"
  local SRC="$SRC_BASE/527.cam4_r"
  cd "$SRC"

  local CAM_DEFS="-DNO_SHR_VMATH -DCO2A -DPERGRO -DPLON=144 -DPLAT=96 -DPLEV=26 -DPCNST=3 -DPCOLS=4 -DPTRM=1 -DPTRN=1 -DPTRK=1 -DSTAGGERED -D_NETCDF -DNO_R16"
  local CFLAGS="$TARGET_FLAGS -fPIC $CAM_DEFS -I. -Iinclude -Inetcdf/include -DSPEC_AUTO_SUPPRESS_OPENMP -DSPEC_AUTO_BYTEORDER=0x12345678 -DSPEC_CASE_FLAG -fvisibility=protected -Wno-implicit-int $SPEC_FLAGS"
  local FFLAGS="$TARGET_FLAGS -fPIC -I. -Iinclude -Inetcdf/include $CAM_DEFS -DSPEC_AUTO_SUPPRESS_OPENMP -w -DHIDE_MPI -D_MPISERIAL -DNO_MPI2 $SPEC_FLAGS"

  # Target 1: lib527.cam4_r.so
  local T1_FILES=$(grep 'add_library(527.cam4_r' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')
  _build_mixed_target "cam4" "lib527.cam4_r.so" "$CFLAGS" "$FFLAGS" "$T1_FILES"

  # Target 2: libcam4_validate_527.so
  local T2_FILES=$(grep 'add_library(cam4_validate_527' CMakeLists.txt | sed 's/add_library([^ ]* SHARED //; s/ *) *//')
  _build_mixed_target "validate" "libcam4_validate_527.so" "$CFLAGS" "$FFLAGS" "$T2_FILES"

  copy_to_build "$SRC/lib527.cam4_r.so"
  copy_to_build "$SRC/libcam4_validate_527.so"
}

build_548() {
  echo "======== Building 548.exchange2_r ========"
  local SRC="$SRC_BASE/548.exchange2_r"
  cd "$SRC"

  local FFLAGS="$TARGET_FLAGS -fPIC -DSPEC_AUTO_SUPPRESS_OPENMP -fwrapv $SPEC_FLAGS"
  flang-new-20 $FFLAGS \
    -fuse-ld=lld -shared -nostdlib \
    -L "$FLANG_DIR" -lFortranRuntime -lFortranDecimal \
    -L "$SYSROOT/usr/lib/aarch64-linux-ohos" -lc -lm \
    -L "$RT_LIB" -lclang_rt.builtins \
    "$OHOS_LIB/libc++_static.a" \
    "$OHOS_LIB/libc++abi.a" \
    "$OHOS_LIB/libunwind.a" \
    exchange2.F90 \
    -o lib548.exchange2_r.so

  verify_so lib548.exchange2_r.so
  copy_to_build "$SRC/lib548.exchange2_r.so"
}

build_549() {
  echo "======== Building 549.fotonik3d_r ========"
  local SRC="$SRC_BASE/549.fotonik3d_r"
  cd "$SRC"
  rm -rf _mod _obj && mkdir -p _mod _obj

  local FFLAGS="$TARGET_FLAGS -fPIC -I. -DSPEC_AUTO_SUPPRESS_OPENMP $SPEC_FLAGS -module-dir _mod -I _mod"

  # Compile in dependency order (modules first)
  local FILES=(
    parameter.f90 globalvar.F90 MPI_dummy.F90 readline.f90 timerRoutine.f90
    communicate.F90 power.F90 calcflops.F90 material.F90 mur.F90
    PlaneSource.F90 PEC.F90 UPML.F90 huygens.F90 update.F90
    writeout.F90 init.F90 leapfrog.F90 yeemain.F90
  )

  for f in "${FILES[@]}"; do
    flang-new-20 $FFLAGS -c "$f" -o "_obj/${f%.*}.o"
    echo "  compiled $f"
  done

  link_shared lib549.fotonik3d_r.so _obj/*.o
  verify_so lib549.fotonik3d_r.so
  copy_to_build "$SRC/lib549.fotonik3d_r.so"
}

build_554() {
  echo "======== Building 554.roms_r ========"
  local SRC="$SRC_BASE/554.roms_r"
  cd "$SRC"
  rm -rf _mod _obj && mkdir -p _mod _obj

  local FFLAGS="$TARGET_FLAGS -fPIC -I. -DBENCHMARK -DNestedGrids=1 -DNO_GETTIMEOFDAY \
    -DSPEC_AUTO_SUPPRESS_OPENMP -DNDEBUG $SPEC_FLAGS -module-dir _mod -I _mod"

  # All source files from CMakeLists.txt
  local FILES=(
    bbl.F90 bc_2d.F90 exchange_2d.F90 mod_param.F90 mod_kinds.F90
    mod_grid.F90 mod_scalars.F90 mod_bbl.F90 mod_forces.F90 mod_ocean.F90
    mod_sediment.F90 mod_parallel.F90 mod_iounits.F90 mod_strings.F90
    mod_stepping.F90 mp_exchange.F90 bc_3d.F90 exchange_3d.F90 bc_bry2d.F90
    bc_bry3d.F90 bulk_flux.F90 mod_mixing.F90 bvf_mix.F90 conv_2d.F90
    conv_3d.F90 conv_bry2d.F90 conv_bry3d.F90 diag.F90 analytical.F90
    distribute.F90 mod_ncparam.F90 mod_biology.F90 mod_eclight.F90
    mod_boundary.F90 mod_clima.F90 mod_sources.F90 mod_netcdf.F90
    strings.F90 forcing.F90 mod_coupling.F90 frc_adjust.F90 get_data.F90
    mod_obs.F90 get_idata.F90 mod_tides.F90 nf_fread3d.F90 nf_fread4d.F90
    gls_corstep.F90 tkebc_im.F90 gls_prestep.F90 hmixing.F90 ini_fields.F90
    set_depth.F90 t3dbc_im.F90 u2dbc_im.F90 u3dbc_im.F90 v2dbc_im.F90
    v3dbc_im.F90 zetabc.F90 initial.F90 ini_adjust.F90 mod_fourdvar.F90
    state_addition.F90 state_copy.F90 metrics.F90 ocean_coupler.F90
    mod_coupler.F90 roms_export.F90 roms_import.F90 omega.F90 rho_eos.F90
    mod_eoscoef.F90 set_massflux.F90 stiffness.F90 wpoints.F90
    mod_storage.F90 interp_floats.F90 lmd_bkpp.F90 shapiro.F90 lmd_skpp.F90
    lmd_swfrac.F90 lmd_vmix.F90 main2d.F90 dotproduct.F90 obc_adjust.F90
    oi_update.F90 radiation_stress.F90 mod_diags.F90 set_avg.F90
    mod_average.F90 set_tides.F90 set_vbc.F90 step2d.F90 obc_volcons.F90
    wetdry.F90 step_floats.F90 mod_floats.F90 vwalk_floats.F90 utility.F90
    main3d.F90 biology.F90 my25_corstep.F90 my25_prestep.F90 rhs3d.F90
    pre_step3d.F90 prsgrd.F90 t3dmix.F90 uv3dmix.F90 sediment.F90
    sed_bed.F90 sed_bedload.F90 sed_fluxes.F90 sed_settling.F90
    sed_surface.F90 set_zeta.F90 step3d_t.F90 mpdata_adiff.F90 step3d_uv.F90
    wvelocity.F90 output.F90 set_data.F90 set_2dfld.F90 set_3dfld.F90
    abort.F90 ocean_control.F90 back_cost.F90 cgradient.F90 nf_fread2d.F90
    nf_fread2d_bry.F90 nf_fread3d_bry.F90 state_dotprod.F90
    state_initialize.F90 state_scale.F90 cost_grad.F90 normalization.F90
    nf_fwrite2d.F90 nf_fwrite3d.F90 white_noise.F90 nrutil.F90 packing.F90
    posterior.F90 posterior_var.F90 state_product.F90 propagator.F90
    random_ic.F90 sum_grad.F90 zeta_balance.F90 checkadj.F90 checkdefs.F90
    checkerror.F90 checkvars.F90 close_io.F90 congrad.F90 def_avg.F90
    def_var.F90 def_diags.F90 def_dim.F90 def_error.F90 def_floats.F90
    def_gst.F90 def_hessian.F90 def_his.F90 def_impulse.F90 def_info.F90
    def_ini.F90 def_lanczos.F90 def_mod.F90 def_norm.F90 def_rst.F90
    def_station.F90 def_tides.F90 extract_obs.F90 extract_sta.F90
    frc_weak.F90 gasdev.F90 get_2dfld.F90 get_2dfldr.F90 get_3dfld.F90
    get_3dfldr.F90 get_bounds.F90 get_cycle.F90 get_date.F90 get_grid.F90
    get_gst.F90 get_ngfld.F90 get_ngfldr.F90 get_state.F90
    get_varcoords.F90 grid_coords.F90 interpolate.F90 ini_lanczos.F90
    inp_par.F90 ran_state.F90 lubksb.F90 ludcmp.F90 mp_routines.F90
    nf_fwrite2d_bry.F90 nf_fwrite3d_bry.F90 nf_fwrite4d.F90 obs_cost.F90
    obs_depth.F90 obs_initial.F90 obs_read.F90 obs_write.F90 ran1.F90
    regrid.F90 rep_matrix.F90 set_2dfldr.F90 set_3dfldr.F90 set_diags.F90
    set_ngfld.F90 set_ngfldr.F90 set_scoord.F90 set_weights.F90
    stats_modobs.F90 timers.F90 wrt_avg.F90 wrt_diags.F90 wrt_error.F90
    wrt_floats.F90 wrt_gst.F90 wrt_hessian.F90 wrt_his.F90 wrt_impulse.F90
    wrt_info.F90 wrt_ini.F90 wrt_rst.F90 wrt_station.F90 wrt_tides.F90
    mod_arrays.F90 mod_nesting.F90 esmf_roms.F90 master.F90
  )

  compile_fortran_multipass "_mod" "_obj" "$FFLAGS" "${FILES[@]}"

  link_shared lib554.roms_r.so _obj/*.o
  verify_so lib554.roms_r.so
  copy_to_build "$SRC/lib554.roms_r.so"
}

# Helper: build a target with mixed C/C++/Fortran sources
_build_mixed_target() {
  local NAME="$1"
  local OUTPUT="$2"
  local CFLAGS_LOCAL="$3"
  local FFLAGS_LOCAL="$4"
  local ALLFILES="$5"
  local OBJDIR="_obj_${NAME}"
  local MODDIR="_mod_${NAME}"

  rm -rf "$OBJDIR" "$MODDIR" && mkdir -p "$OBJDIR" "$MODDIR"
  local FFLAGS_FULL="$FFLAGS_LOCAL -module-dir $MODDIR -I $MODDIR"

  echo "=== [$NAME] Compiling ==="
  compile_c_files "$CFLAGS_LOCAL" "$OBJDIR" $ALLFILES

  local F_FILES=($(extract_fortran_files $ALLFILES))
  if [ ${#F_FILES[@]} -gt 0 ]; then
    compile_fortran_multipass "$MODDIR" "$OBJDIR" "$FFLAGS_FULL" "${F_FILES[@]}"
  fi

  echo "=== [$NAME] Linking ==="
  link_shared "$OUTPUT" "$OBJDIR"/*.o
  verify_so "$OUTPUT"
}

# --- Main ---

ALL_BENCHMARKS="503 507 521 527 548 549 554"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <benchmark...> | all"
  echo "Available benchmarks: $ALL_BENCHMARKS"
  exit 1
fi

TARGETS="$@"
if [ "$1" = "all" ]; then
  TARGETS="$ALL_BENCHMARKS"
fi

for bench in $TARGETS; do
  case "$bench" in
    503) build_503 ;;
    507) build_507 ;;
    521) build_521 ;;
    527) build_527 ;;
    548) build_548 ;;
    549) build_549 ;;
    554) build_554 ;;
    *) echo "Unknown benchmark: $bench (available: $ALL_BENCHMARKS)"; exit 1 ;;
  esac
  echo ""
done

echo "=== All requested benchmarks built successfully ==="
