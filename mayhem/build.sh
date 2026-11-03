#!/usr/bin/env bash
#
# mayhem/build.sh — builds the two SPF fuzz harnesses (sanitized, DWARF 3), their standalone
# reproducers, and the portable test runner (normal flags). Needs only clang and cmake; the
# portable subset of hMailServer has no third-party dependency, so nothing is fetched.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

SERVER="$SRC/hmailserver/source/Server"
PORTABLE="$SERVER/Portable"
OUT="$SRC/out"           # gitignored upstream (/out/)
FUZZ_OBJ="$OUT/fuzz-obj"

# The SPF sources the harnesses exercise (same list as the HM_FUZZ library in CMakeLists.txt).
SPF_SOURCES=(SPFSyntax SPFAddress SPFRecord SPFMacroExpander SPFTestLookup)

# 1) Sanitized project objects. -fsanitize=fuzzer-no-link adds coverage instrumentation to the
#    code under test; the harness entry point links the engine afterwards.
rm -rf "$FUZZ_OBJ"
mkdir -p "$FUZZ_OBJ"
CXXFLAGS_FUZZ=(-std=c++17 -I"$PORTABLE" -I"$SERVER" $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link)
objs=()
for s in "${SPF_SOURCES[@]}"; do
  "$CXX" "${CXXFLAGS_FUZZ[@]}" -c "$SERVER/SMTP/SPF/$s.cpp" -o "$FUZZ_OBJ/$s.o"
  objs+=("$FUZZ_OBJ/$s.o")
done

# 2) Leak detection off at build time; the driver for the standalone reproducers is built as C.
"$CXX" -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_OBJ/lsan_off.o"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_OBJ/standalone_main.o"

# 3) Harnesses: fuzzer + standalone binary each.
for h in "FuzzSPFRecord:fuzz-spf-record" "FuzzSPFMacroExpander:fuzz-spf-macro-expander"; do
  src="${h%%:*}"; bin="${h##*:}"
  "$CXX" "${CXXFLAGS_FUZZ[@]}" -c "$PORTABLE/Fuzz/$src.cpp" -o "$FUZZ_OBJ/$src.o"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$FUZZ_OBJ/$src.o" "${objs[@]}" "$FUZZ_OBJ/lsan_off.o" -o "$SRC/$bin"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$FUZZ_OBJ/$src.o" "${objs[@]}" "$FUZZ_OBJ/lsan_off.o" "$FUZZ_OBJ/standalone_main.o" -o "$SRC/$bin-standalone"
done

# 4) The project's own test runner (SPF record/macro/evaluator testers + the RFC 7208 conformance
#    suite), with the project's NORMAL flags: no sanitizers.
cmake -S "$SRC" -B "$OUT/tests" -G Ninja -DCMAKE_BUILD_TYPE=Release -DHM_SANITIZE=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$OUT/tests" -j"$MAYHEM_JOBS" --target hmailserver-core-tests
