#!/usr/bin/env bash
#
# mayhem/build.sh — build Little CMS (sanitized, for fuzzing) + every fuzz harness + the testbed oracle.
# Runs in the commit image as `mayhem` in /mayhem. Re-runnable and offline: nothing is fetched.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
BUILD="$SRC/mayhem/_build"          # gitignored by mayhem/.gitignore, so `git clean -ffdX` removes it
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# The standalone driver is C; the libFuzzer link goes through $CXX, so build the driver as a C object.
mkdir -p "$BUILD"
# 1) The library, sanitized + coverage-instrumented (fuzzer-no-link: SanCov without the libFuzzer main).
cmake -S "$SRC" -B "$BUILD/fuzz" -G Ninja \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="-O1 $FUZZ_FLAGS -fsanitize=fuzzer-no-link" \
  -DLCMS2_BUILD_SHARED=OFF -DLCMS2_BUILD_STATIC=ON \
  -DLCMS2_BUILD_TOOLS=OFF -DLCMS2_BUILD_TESTS=OFF -DLCMS2_WITH_THREADS=ON
cmake --build "$BUILD/fuzz" -j"$MAYHEM_JOBS"
LIB="$(find "$BUILD/fuzz" -name 'liblcms2*.a' | head -n1)"
[ -f "$LIB" ] || { echo "build.sh: liblcms2 static library not found" >&2; exit 1; }

# 2) Harnesses: OSS-Fuzz's set (mayhem/harnesses) + upstream's in-tree fuzzers/fuzzers.c (as lcms_fuzzer).
$CC $FUZZ_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"
$CXX $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"

build_harness() {   # <name> <source>
  local name="$1" src="$2"
  $CC $FUZZ_FLAGS -fsanitize=fuzzer-no-link -O1 -I"$SRC/include" -c "$src" -o "$BUILD/$name.o"
  $CXX $FUZZ_FLAGS $LIB_FUZZING_ENGINE "$BUILD/$name.o" "$BUILD/lsan_off.o" "$LIB" -o "$SRC/$name"
  $CXX $FUZZ_FLAGS "$BUILD/$name.o" "$BUILD/standalone_main.o" "$BUILD/lsan_off.o" "$LIB" -o "$SRC/$name-standalone"
}

build_harness lcms_fuzzer "$SRC/fuzzers/fuzzers.c"
for src in "$SRC"/mayhem/harnesses/*.c; do
  build_harness "$(basename "$src" .c)" "$src"
done

# 3) The project's own testbed (testcms), NORMAL flags: no sanitizers, no DWARF pin. test.sh only RUNS it.
cmake -S "$SRC" -B "$BUILD/test" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
  -DLCMS2_BUILD_SHARED=OFF -DLCMS2_BUILD_STATIC=ON \
  -DLCMS2_BUILD_TOOLS=OFF -DLCMS2_BUILD_TESTS=ON -DLCMS2_WITH_THREADS=ON
cmake --build "$BUILD/test" -j"$MAYHEM_JOBS" --target testcms
[ -x "$BUILD/test/testbed/testcms" ] || { echo "build.sh: testcms not built" >&2; exit 1; }
