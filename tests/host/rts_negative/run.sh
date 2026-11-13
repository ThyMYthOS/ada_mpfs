#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Negative builds of the runtime variants of crates/mpfs_rts: what a program of one profile
# or hart class must not be able to do, and the one place for each negative build that exists elsewhere.
#
#   - Profile restrictions, with the compiler against the variants: a task in the light profile
#     (violation of the implicit restriction No_Tasking: the light runtime has no tasking), and in the
#     light-tasking and embedded profiles an abort statement (No_Abort_Statements) and a task allocator
#     (No_Task_Allocators). The same task in a library package compiles in the light-tasking and the
#     embedded profile, and an abort-free, allocator-free unit does in all three: the controls.
#   - The ABI of the hart classes against the libraries of the variants: an object of the E51 (lp64, no
#     F or D) linked with the library of the U54 (lp64d) fails with the linker's float ABI message,
#     and so does the reverse; objects and library of one hart class link (the link has no linker
#     script and no partition data, so unresolved symbols are ignored: only the ABI is under test).
#   - The clock of the partition package against the runtime (RTS-025): the package that
#     config/gen/standalone.py writes compiles against each of the three profiles with the 1 MHz of the
#     runtime, and with 2 MHz, 999 999 Hz, 100 MHz or 32 768 Hz it is rejected with the message of the
#     check (Compile_Time_Error), as is the 1 MHz package against a copy of a runtime whose
#     Clock_Frequency is 2 MHz.
#   - The other negative builds (a mandatory link symbol missing, a mask that
#     mixes the E51 and the U54, a stack size that is not a multiple of 16, the console ram_fifo before
#     SMP) are the cases of tests/host/rts_boot and tests/host/standalone. They are not repeated here;
#     this suite only checks that each of them is still there, under the name and with the message
#     that docs/assurance/tests.md lists.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.
#
# @verifies RTS-020, RTS-025, BLD-002

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CRATE="$ROOT/crates/mpfs_rts"
GEN="$CRATE/gen_runtime.sh"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# -- where each negative build lives (no toolchain needed) -----------------------------------
# covered <what> <file> <fixed string that must be in it>
covered () {
  if grep -qF -- "$3" "$ROOT/$2"; then pass "negative build: $1 (in $2)"
  else fail "negative build: $1 is not in $2 any more (no line with: $3)"; fi
}
covered "a mandatory symbol missing (undefined reference)" tests/host/rts_boot/run.sh \
  "negative missing_boot_role e51 \"undefined reference to \\\`__mpfs_boot_role'\""
covered "a mandatory symbol missing (the mask)" tests/host/rts_boot/run.sh \
  "negative missing_harts_mask e51"
covered "a RTC clock that is not the Clock_Frequency of the runtime (the build of an image)" tests/host/standalone/run.sh \
  "negative clock_not_rtc_toggle_hz e51 \"Clock_Frequency of the runtime is not Clocks.Rtc_Toggle_Hz\""
covered "a mask that mixes the E51 and the U54 (Compile_Time_Error)" tests/host/standalone/run.sh \
  "negative mask_mixes_e51_and_u54 e51 \"a partition mask must not mix the E51 and U54 harts\""
covered "a stack size that is not a multiple of 16 (linker)" tests/host/rts_boot/run.sh \
  "negative stack_size_not_16 e51"
covered "a stack size that is not a multiple of 16 (Compile_Time_Error)" tests/host/standalone/run.sh \
  "negative stack_size_not_16 e51"
covered "an interrupt stack size that is not a multiple of 16" tests/host/standalone/run.sh \
  "negative interrupt_stack_size_not_16 e51"
covered "a secondary stack size that is not a multiple of 16" tests/host/standalone/run.sh \
  "negative secondary_stack_size_not_16 e51"
covered "the console ram_fifo before SMP (Compile_Time_Error)" tests/host/standalone/run.sh \
  "negative console_ram_fifo_before_smp e51"
covered "E51 and U54 objects must not mix (the bare images)" tests/negative/cases.list \
  "abi_e51_start_u54_code"

. "$ROOT/tools/mpfs-env.sh"
if ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  skip "everything else: the pinned toolchain is not installed (./x toolchain install gnat)"
  echo "summary: $fails failure(s)"; [ "$fails" -eq 0 ]; exit
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "everything else: zstd or GNU tar is not installed"
  echo "summary: $fails failure(s)"; [ "$fails" -eq 0 ]; exit
fi

# -- the variants (built once into build/rts, where ./x build keeps them) -------------------------------
for v in "light e51" "light u54" "light-tasking e51" "embedded e51"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done
rts="$ROOT/build/rts"

# The switches of the hart class: what the runtime says, as gprbuild passes them to every unit of
# an application (a bare driver call does not read runtime.xml).
isa () {   # isa <variant>: -march and -mabi of the variant
  sed -n 's/.*Common_Required_Switches := (\(.*\));/\1/p' "$rts/$1-cpus1-m/runtime.xml" \
    | tr -d '",' | tr ' ' '\n' | grep -E '^-m(arch|abi)=' | paste -sd' ' -
}

# -- profile restrictions ----------------------------------------------------------------------------
mkdir -p "$work/src"
cat > "$work/src/task_pkg.ads" <<'EOF'
package Task_Pkg is
   task Worker;
end Task_Pkg;
EOF
cat > "$work/src/task_pkg.adb" <<'EOF'
package body Task_Pkg is
   task body Worker is
   begin
      null;
   end Worker;
end Task_Pkg;
EOF
cat > "$work/src/abort_it.adb" <<'EOF'
with Task_Pkg;
procedure Abort_It is
begin
   abort Task_Pkg.Worker;
end Abort_It;
EOF
cat > "$work/src/alloc_it.ads" <<'EOF'
package Alloc_It is
   task type Worker;
   type Worker_Access is access Worker;
   procedure Start;
end Alloc_It;
EOF
cat > "$work/src/alloc_it.adb" <<'EOF'
package body Alloc_It is
   task body Worker is
   begin
      null;
   end Worker;
   procedure Start is
      P : constant Worker_Access := new Worker;
      pragma Unreferenced (P);
   begin
      null;
   end Start;
end Alloc_It;
EOF
cat > "$work/src/plain.adb" <<'EOF'
procedure Plain is
   X : constant Integer := 1;
   pragma Unreferenced (X);
begin
   null;
end Plain;
EOF

# compile <name> <variant> <unit.adb ...>: -gnat2022 against the runtime of the variant, in a directory of
# its own; log in $work/<name>.log, the status in $rc, the objects in $work/<name>/
compile () {
  local name="$1" variant="$2"; shift 2
  mkdir -p "$work/$name"
  # shellcheck disable=SC2046
  ( cd "$work/$name" && riscv64-elf-gcc -c -gnat2022 -gnatwa -gnatwe $(isa "$variant") \
      --RTS="$rts/$variant-cpus1-m" -I"$work/src" "${@/#/$work/src/}" ) >"$work/$name.log" 2>&1
  rc=$?
}

# fails <name> <variant> <message> <unit.adb ...>: must fail with the message and leave no object
fails_with () {
  local name="$1" variant="$2" msg="$3"; shift 3
  compile "$name" "$variant" "$@"
  if [ "$rc" -eq 0 ]; then fail "$name: it compiled, it must not"
  elif ! grep -qF -- "$msg" "$work/$name.log"; then fail "$name: it failed, but not with \"$msg\":"; sed 's/^/    /' "$work/$name.log" >&2
  elif [ -n "$(find "$work/$name" -name '*.o' 2>/dev/null)" ]; then fail "$name: it failed but left an object"
  else pass "$name fails (\"$msg\")"; fi
}
builds () {
  local name="$1" variant="$2"; shift 2
  compile "$name" "$variant" "$@"
  if [ "$rc" -ne 0 ]; then fail "$name: it must compile"; sed 's/^/    /' "$work/$name.log" >&2
  elif [ -z "$(find "$work/$name" -name '*.o' 2>/dev/null)" ]; then fail "$name: it compiled and left no object"
  else pass "$name builds"; fi
}

fails_with light_task_e51 light-e51 'violation of implicit restriction "No_Tasking"' task_pkg.adb
fails_with light_task_u54 light-u54 'violation of implicit restriction "No_Tasking"' task_pkg.adb
builds light_plain_e51 light-e51 plain.adb
builds tasking_task_e51 light-tasking-e51 task_pkg.adb
builds embedded_task_e51 embedded-e51 task_pkg.adb
builds tasking_plain_e51 light-tasking-e51 plain.adb
fails_with tasking_abort_e51 light-tasking-e51 'violation of restriction "No_Abort_Statements"' abort_it.adb
fails_with embedded_abort_e51 embedded-e51 'violation of restriction "No_Abort_Statements"' abort_it.adb
fails_with tasking_allocator_e51 light-tasking-e51 'violation of restriction "No_Task_Allocators"' alloc_it.adb
fails_with embedded_allocator_e51 embedded-e51 'violation of restriction "No_Task_Allocators"' alloc_it.adb

# -- the float ABI of the hart classes against the libraries of the variants --------------------------------
for hart in e51 u54; do
  compile "obj_$hart" "light-$hart" plain.adb
  [ "$rc" -eq 0 ] || { fail "obj_$hart: the object does not compile"; cat "$work/obj_$hart.log" >&2; }
done
abi () { riscv64-elf-readelf -h "$1" | sed -n 's/.*Flags: *//p'; }
case "$(abi "$work/obj_e51/plain.o")" in *soft-float*) pass "the E51 object is a soft-float object (lp64)" ;;
  *) fail "the E51 object is a soft-float object (lp64): $(abi "$work/obj_e51/plain.o")" ;; esac
case "$(abi "$work/obj_u54/plain.o")" in *double-float*) pass "the U54 object is a double-float object (lp64d)" ;;
  *) fail "the U54 object is a double-float object (lp64d): $(abi "$work/obj_u54/plain.o")" ;; esac

# link <object> <library variant>: the object and the library of the variant, no linker script
link () {
  riscv64-elf-gcc -nostdlib -nostartfiles -o "$work/link.elf" "$1" -Wl,-u,_start \
    -Wl,--unresolved-symbols=ignore-all "$rts/$2-cpus1-m/adalib/libgnat.a" >"$work/link.log" 2>&1
}
rm -f "$work/link.elf"; link "$work/obj_e51/plain.o" light-e51; rc=$?
{ [ $rc -eq 0 ] && [ -f "$work/link.elf" ]; } && pass "control: the E51 object and the library of the E51 link" \
  || { fail "control: the E51 object and the library of the E51 link"; cat "$work/link.log" >&2; }
rm -f "$work/link.elf"; link "$work/obj_u54/plain.o" light-u54; rc=$?
{ [ $rc -eq 0 ] && [ -f "$work/link.elf" ]; } && pass "control: the U54 object and the library of the U54 link" \
  || { fail "control: the U54 object and the library of the U54 link"; cat "$work/link.log" >&2; }
for pair in "e51:u54" "u54:e51"; do
  obj="${pair%%:*}"; lib="${pair#*:}"
  rm -f "$work/link.elf"; link "$work/obj_$obj/plain.o" "light-$lib"; rc=$?
  if [ $rc -eq 0 ]; then fail "an object of the $obj linked with the library of the $lib: it linked, it must not"
  elif [ -f "$work/link.elf" ]; then fail "an object of the $obj linked with the library of the $lib: it failed but left an image"
  elif ! grep -qF "float modules with" "$work/link.log"; then
    fail "an object of the $obj linked with the library of the $lib failed, but not with the float ABI message:"; sed 's/^/    /' "$work/link.log" >&2
  else pass "an object of the $obj linked with the library of the $lib fails (float ABI)"; fi
done

# -- the clock of the partition package against Clock_Frequency of the runtime ---------------------------
MSG='Clock_Frequency of the runtime is not Clocks.Rtc_Toggle_Hz'
mpfs_find_python
# try_clock <profile> <Rtc_Toggle_Hz> <runtime dir>: compile the package of the generator with that frequency; log in $work/clk.err
try_clock () {
  rm -rf "$work/clk"; mkdir -p "$work/clk"
  "$MPFS_PYTHON" -I "$ROOT/config/gen/standalone.py" --hart e51 --profile "$1" --rtc-toggle-hz "$2" \
    --output "$work/clk/mpfs_partition.ads" || return 2
  (cd "$work/clk" && riscv64-elf-gcc -c -gnatc -gnat2022 -gnatwa -gnatwe -gnaty --RTS="$3" mpfs_partition.ads) 2>"$work/clk.err"
}
for pv in "light light-e51" "light-tasking light-tasking-e51" "embedded embedded-e51"; do
  prof="${pv%% *}"; d="$rts/${pv#* }-cpus1-m"
  if try_clock "$prof" 1000000 "$d"; then pass "$prof: a partition with Rtc_Toggle_Hz = 1 MHz compiles"
  else fail "$prof: a partition with Rtc_Toggle_Hz = 1 MHz compiles ($(cat "$work/clk.err"))"; fi
  for hz in 2000000 999999 100000000 32768; do
    if try_clock "$prof" "$hz" "$d"; then
      fail "$prof: a partition with Rtc_Toggle_Hz = $hz is rejected"
    elif grep -q "$MSG" "$work/clk.err"; then
      pass "$prof: a partition with Rtc_Toggle_Hz = $hz is rejected with the message of the check"
    else
      fail "$prof: a partition with Rtc_Toggle_Hz = $hz is rejected with the message of the check ($(cat "$work/clk.err"))"
    fi
  done
done

# the other way round: the partition says 1 MHz, the runtime has another Clock_Frequency (a copy of the variant)
cp -r "$rts/light-tasking-e51-cpus1-m" "$work/rts-2mhz"
chmod -R u+w "$work/rts-2mhz"
rm -f "$work/rts-2mhz"/adainclude/s-bbbopa.ad? "$work/rts-2mhz"/adalib/s-bbbopa.ali
sed 's/Decrementer_Frequency : constant Positive := 1_000_000;/Decrementer_Frequency : constant Positive := 2_000_000;/' \
  "$rts/light-tasking-e51-cpus1-m/adainclude/s-bbbopa.ads" >"$work/rts-2mhz/adainclude/s-bbbopa.ads"
if grep -q '2_000_000' "$work/rts-2mhz/adainclude/s-bbbopa.ads"; then
  if try_clock light-tasking 1000000 "$work/rts-2mhz"; then
    fail "a runtime whose Clock_Frequency is 2 MHz is rejected by the 1 MHz partition"
  elif grep -q "$MSG" "$work/clk.err"; then
    pass "a runtime whose Clock_Frequency is 2 MHz is rejected by the 1 MHz partition"
  else
    fail "a runtime whose Clock_Frequency is 2 MHz is rejected by the 1 MHz partition ($(cat "$work/clk.err"))"
  fi
else
  fail "the copy of the runtime has a Clock_Frequency of 2 MHz"
fi

echo "summary: $fails failure(s)"
[ "$fails" -eq 0 ]
