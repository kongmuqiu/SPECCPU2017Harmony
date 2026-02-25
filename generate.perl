# enable -flto
$enable_lto = 1;

sub add_target {
    my $target = $_[0];

    # ── FIX: work with LOCAL copies to prevent flag accumulation across targets ──
    my $lflags    = $bench_flags;
    my $lcflags   = $bench_cflags;
    my $lcxxflags = $bench_cxxflags;
    my $lfflags   = $bench_fflags;
    my $lfppflags = $bench_fppflags;

    # drop trailing '*' from source file names
    foreach my $source (@sources) {
        $source =~ s{\*$}{};
    }

    my @additional_sources = ();
    if ($target eq "diffwrf_521") {
        # add missing sources due to split module folder
        @additional_sources = ("module_cam_shr_const_mod.F90", "module_cam_shr_kind_mod.F90", "module_gfs_machine.F90", "module_gfs_physcons.F90", "ESMF_Fraction.F90");
    }
    print(FH "add_library(", $target, " SHARED ", (join " ", @sources), " ", (join " ", @additional_sources), ")\n");

    # ── Benchmark-specific quirks (added to local copies only) ──
    if ($target eq "521.wrf_r") {
        $lcflags .= " -DSPEC_CASE_FLAG";
        $lfflags .= " -fconvert=big-endian";
    }
    if ($target eq "527.cam4_r") {
        $lcflags .= " -DSPEC_CASE_FLAG";
    }
    if ($target eq "554.roms_r") {
        $lflags .= " -DNDEBUG";
    }

    # Drop unwanted Fortran preprocessor flags
    $lfppflags =~ s{-w -m literal-single.pm -m c-comment.pm}{};
    $lfppflags =~ s{-w -m literal.pm}{};

    # Combine Fortran flags
    $lfflags = $lfflags . " " . $lfppflags;

    # ── Extract -I flags for target_include_directories (deduplicated) ──
    my %seen_incs;
    my @inc_dirs;
    for my $flagset ($lflags, $lcflags, $lcxxflags, $lfflags) {
        for my $flag (split(/\s+/, $flagset)) {
            if ($flag =~ /^-I(.+)/) {
                my $dir = $1;
                unless ($seen_incs{$dir}++) {
                    push @inc_dirs, $dir;
                }
            }
        }
    }
    for my $dir (@inc_dirs) {
        print(FH "target_include_directories(", $target, " PRIVATE ", $dir, ")\n");
    }

    # ── Build per-language benchmark-specific flags (from object.pm + quirks) ──
    # Common flags from object.pm apply to all languages
    my $c_specific   = join(" ", grep { $_ ne '' } ($lcflags, $lflags));
    my $cxx_specific = join(" ", grep { $_ ne '' } ($lcxxflags, $lflags));
    my $f_specific   = join(" ", grep { $_ ne '' } ($lfflags, $lflags));
    # Trim leading/trailing whitespace
    $c_specific   =~ s/^\s+|\s+$//g;
    $cxx_specific =~ s/^\s+|\s+$//g;
    $f_specific   =~ s/^\s+|\s+$//g;

    # ── Determine LTO tier ──
    my $lto_var   = '';
    my $lto_label = 'NONE';
    if ($enable_lto) {
        if ($target eq "502.gcc_r") {
            # -flto miscompiles 502.gcc_r, skip entirely
        } elsif ($target eq "507.cactuBSSN_r" or $target eq "510.parest_r" or
                 $target eq "521.wrf_r" or $target eq "diffwrf_521" or
                 $target eq "526.blender_r" or $target eq "imagevalidate_526" or
                 $target eq "527.cam4_r" or $target eq "cam4_validate_527") {
            $lto_var   = ' ${SPEC_LTO_THIN}';
            $lto_label = 'THIN';
        } else {
            $lto_var   = ' ${SPEC_LTO}';
            $lto_label = 'FULL';
        }
    }

    # ── Determine MATH tier (C/CXX only, never Fortran; validators get NONE) ──
    my $is_validator = ($target =~ /^(imagevalidate_|diffwrf_|cam4_validate_|ldecod_)/);
    my $math_var   = '';
    my $math_label = 'NONE';
    if (!$is_validator) {
        # Aggressive: FP-heavy benchmarks with explicit validation tolerances
        if ($target eq "503.bwaves_r" or $target eq "508.namd_r" or
            $target eq "519.lbm_r" or $target eq "538.imagick_r" or
            $target eq "544.nab_r") {
            $math_var   = ' ${SPEC_MATH_AGGR}';
            $math_label = 'AGGRESSIVE';
        }
        # Basic: most benchmarks benefit from -fno-math-errno -fno-trapping-math
        elsif ($target eq "505.mcf_r" or $target eq "507.cactuBSSN_r" or
               $target eq "510.parest_r" or $target eq "511.povray_r" or
               $target eq "521.wrf_r" or $target eq "525.x264_r" or
               $target eq "526.blender_r" or $target eq "527.cam4_r" or
               $target eq "531.deepsjeng_r" or $target eq "541.leela_r" or
               $target eq "548.exchange2_r" or $target eq "549.fotonik3d_r" or
               $target eq "554.roms_r" or $target eq "557.xz_r") {
            $math_var   = ' ${SPEC_MATH_BASIC}';
            $math_label = 'BASIC';
        }
        # NONE: 500.perlbench_r, 502.gcc_r, 520.omnetpp_r, 523.xalancbmk_r
    }

    # ── Fortran-specific tune flags ──
    my $fortran_extra = '';
    if ($target eq "548.exchange2_r") {
        $fortran_extra = ' ${SPEC_FLANG_INT_TUNE}';
    }

    # ── Print comment header ──
    my $label = $target;
    $label .= ": validator tool" if $is_validator;
    my $comment = "$label: LTO=$lto_label";
    $comment .= ", MATH=$math_label" if ($math_label ne 'NONE' or $fortran_extra ne '');
    print(FH "# ", $comment, "\n");

    # ── Build and print compile options using spec_flags.cmake variables ──
    # C line: ${SPEC_CC_VIS} <benchmark-specific> ${SPEC_BASE} [LTO] [MATH] ${SPEC_CC_WARN} ${SPEC_CC_COMPAT}
    my $c_line = '${SPEC_CC_VIS}';
    $c_line .= " $c_specific" if $c_specific ne '';
    $c_line .= ' ${SPEC_BASE}' . $lto_var . $math_var . ' ${SPEC_CC_WARN} ${SPEC_CC_COMPAT}';

    # CXX line: same structure as C
    my $cxx_line = '${SPEC_CC_VIS}';
    $cxx_line .= " $cxx_specific" if $cxx_specific ne '';
    $cxx_line .= ' ${SPEC_BASE}' . $lto_var . $math_var . ' ${SPEC_CC_WARN} ${SPEC_CC_COMPAT}';

    # Fortran line: <benchmark-specific> ${SPEC_BASE} [LTO] [FLANG_TUNE] (no VIS/MATH/WARN/COMPAT)
    my $f_line = '';
    $f_line .= "$f_specific " if $f_specific ne '';
    $f_line .= '${SPEC_BASE}' . $lto_var . $fortran_extra;

    print(FH "target_compile_options(", $target, " PRIVATE\n");
    print(FH "\t\$<\$<COMPILE_LANGUAGE:C>:", $c_line, ">\n");
    print(FH "\t\$<\$<COMPILE_LANGUAGE:CXX>:", $cxx_line, ">\n");
    print(FH "\t\$<\$<COMPILE_LANGUAGE:Fortran>:", $f_line, ">)\n");

    # Handle same Fortran source in multiple targets (e.g. 521.wrf_r)
    print(FH "set_target_properties(", $target, " PROPERTIES Fortran_MODULE_DIRECTORY \${CMAKE_CURRENT_BINARY_DIR}/", $target, ")\n");
    print(FH "target_include_directories(", $target, " PUBLIC \${CMAKE_CURRENT_BINARY_DIR}/", $target, ")\n");
}

for $benchmark ("500.perlbench_r", "502.gcc_r", "505.mcf_r", "520.omnetpp_r", "523.xalancbmk_r", "525.x264_r", "531.deepsjeng_r", "541.leela_r", "548.exchange2_r", "557.xz_r", "503.bwaves_r", "507.cactuBSSN_r", "508.namd_r", "510.parest_r", "511.povray_r", "519.lbm_r", "521.wrf_r", "526.blender_r", "527.cam4_r", "538.imagick_r", "544.nab_r", "549.fotonik3d_r", "554.roms_r") {
    $bench_flags = $bench_cflags = $bench_cxxflags = $bench_fflags = $bench_fppflags = "";
    require "./benchspec/CPU/" . $benchmark . "/Spec/object.pm";
    mkdir("entry/src/main/cpp/" . $benchmark);
    system("cp -arv ./benchspec/CPU/" . $benchmark . "/src/* entry/src/main/cpp/" . $benchmark . "/");
    open(FH, '>', "entry/src/main/cpp/" . $benchmark . "/CMakeLists.txt") or die $!;

    # Include centralized flag definitions
    print(FH "include(\${CMAKE_CURRENT_LIST_DIR}/../spec_flags.cmake)\n");

    if ($benchmark eq "511.povray_r") {
        @sources = @{%sources{"povray_r"}};
        add_target("511.povray_r");

        @sources = @{%sources{"imagevalidate_511"}};
        add_target("imagevalidate_511");
    } elsif ($benchmark eq "521.wrf_r") {
        @sources = @{%sources{"wrf_r"}};
        add_target("521.wrf_r");

        @sources = @{%sources{"diffwrf_521"}};
        add_target("diffwrf_521");
    } elsif ($benchmark eq "525.x264_r") {
        @sources = @{%sources{"x264_r"}};
        add_target("525.x264_r");

        @sources = @{%sources{"ldecod_r"}};
        add_target("ldecod_r");

        @sources = @{%sources{"imagevalidate_525"}};
        add_target("imagevalidate_525");
    } elsif ($benchmark eq "526.blender_r") {
        @sources = @{%sources{"blender_r"}};
        add_target("526.blender_r");

        @sources = @{%sources{"imagevalidate_526"}};
        add_target("imagevalidate_526");
    } elsif ($benchmark eq "527.cam4_r") {
        @sources = @{%sources{"cam4_r"}};
        add_target("527.cam4_r");

        @sources = @{%sources{"cam4_validate_527"}};
        add_target("cam4_validate_527");
    } elsif ($benchmark eq "538.imagick_r") {
        @sources = @{%sources{"imagick_r"}};
        add_target("538.imagick_r");

        @sources = @{%sources{"imagevalidate_538"}};
        add_target("imagevalidate_538");
    } else {
        add_target($benchmark);
    }

    if ($benchmark eq "549.fotonik3d_r") {
        # extract OBJ.dat.xz for input
        system("xz -d -k ./benchspec/CPU/549.fotonik3d_r/data/refrate/input/OBJ.dat.xz");
    }

    # zip inputs
    system("rm -rf tmp");
    system("mkdir -p tmp/input tmp/output tmp/compare");
    system("cp -rv ./benchspec/CPU/" . $benchmark . "/data/all/input/* ./benchspec/CPU/" . $benchmark . "/data/refrate/input/* tmp/input/");
    system("cp -rv ./benchspec/CPU/" . $benchmark . "/data/refrate/output/* tmp/output/");
    system("cp -rv ./benchspec/CPU/" . $benchmark . "/data/refrate/compare/* tmp/compare/");
    system("rm -f entry/src/main/resources/rawfile/" . $benchmark . ".zip");
    system("cd tmp && zip -r ../entry/src/main/resources/rawfile/" . $benchmark . ".zip *");
    system("rm -rf tmp");
}

# patch code
# fix compilation
system("sed -i '1s;^;#include <fcntl.h>\\n;' entry/src/main/cpp/500.perlbench_r/perlio.c");
system("sed -i 's/__linux__/__nonexistent__/' entry/src/main/cpp/510.parest_r/source/base/utilities.cc");
system("sed -i 's/#if defined __FreeBSD__/#include <stdio.h>\\n#if 1/' entry/src/main/cpp/520.omnetpp_r/simulator/platdep/platmisc.h");
system("sed -i 's/#if defined.* && !defined.*/#if 0/' entry/src/main/cpp/521.wrf_r/netcdf/include/ncfortran.h");
system("sed -i '1s/^/# define rindex(X,Y) strrchr(X,Y)\\n/' entry/src/main/cpp/521.wrf_r/misc.c");
system("sed -i '1s/^/# define rindex(X,Y) strrchr(X,Y)\\n/' entry/src/main/cpp/521.wrf_r/type.c");
system("sed -i '1s/^/# define rindex(X,Y) strrchr(X,Y)\\n/' entry/src/main/cpp/521.wrf_r/reg_parse.c");
system("sed -i 's/^#ifdef\$/#ifdef SPEC/' entry/src/main/cpp/527.cam4_r/ESMF_AlarmMod.F90");
system("sed -i 's/#if defined.* && !defined.*/#if 0/' entry/src/main/cpp/527.cam4_r/netcdf/include/ncfortran.h");
