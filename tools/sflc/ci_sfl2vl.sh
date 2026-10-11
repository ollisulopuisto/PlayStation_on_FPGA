#!/bin/bash
# Run the archived sfl2vl (evaluation mode, no license file) on probe inputs and
# selected real sources. Expects sflpp.exe and sfl2vlbin.exe on PATH. Never fails
# the job on a conversion error: the error text is the result we want.
set -u
OUT=${1:-out}
mkdir -p "$OUT"
run() {  # run <input.sfl> <outbase>
	local in=$1 base=$2
	( cd "$(dirname "$in")" &&
	  sflpp.exe -nest_comment "$(basename "$in")" > "$OLDPWD/$OUT/$base.pp" 2> "$OLDPWD/$OUT/$base.pp.err";
	  tr -d '\r' < "$OLDPWD/$OUT/$base.pp" | sfl2vlbin.exe -O2 -o "$OLDPWD/$OUT/$base.v" > "$OLDPWD/$OUT/$base.log" 2>&1
	  echo "exit=$?" >> "$OLDPWD/$OUT/$base.log" )
	printf '%-28s %s\n' "$base" "$(grep -m1 -iE 'error|over|stop|exit=' "$OUT/$base.log" | head -c 160)"
}
sfl2vlbin.exe 2>&1 | head -5 || true
for f in tools/sflc/probe/*.sfl; do run "$f" "$(basename "$f" .sfl)"; done
# Real SFL+ sources without %i dependencies, unmodified, to see the first rejected construct.
mkdir -p "$OUT/real"
for f in Timer.sflp bsr_s16.sflp Cache_IR.sflp ram_8x2352.sflp dsdac10.sflp; do
	cp "$f" "$OUT/real/${f%.sflp}.sfl"
	run "$OUT/real/${f%.sflp}.sfl" "real_${f%.sflp}"
done
