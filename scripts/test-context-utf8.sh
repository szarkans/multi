#!/usr/bin/env bash
# Truncation must not hand the reviewers broken UTF-8.
#
# The cap is counted in BYTES, but a Cyrillic letter is two of them. Cut on an
# odd boundary and the last byte is half a letter: the file stops being valid
# UTF-8, and a reviewer that decodes its prompt strictly dies on it. That death
# reads as "backend unavailable", so the run quietly drops to a single model
# instead of failing loudly — the worst possible shape for a review tool.
#
#   bash scripts/test-context-utf8.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

valid_utf8(){ iconv -f utf-8 -t utf-8 <"$1" >/dev/null 2>&1 && echo yes || echo no; }

REPO="$TMP/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t )
# Pure Cyrillic: every character is two bytes, so an odd cap always lands
# mid-letter. 12 bytes per repetition, 6000 bytes total.
: >"$REPO/CLAUDE.md"
i=0
while [ $i -lt 500 ]; do printf 'правило %s\n' "$i" >>"$REPO/CLAUDE.md"; i=$(( i + 1 )); done

echo "== a byte cap that lands mid-letter =="
# Sweep consecutive caps: at least one of them must split a two-byte letter,
# so a single lucky boundary cannot make this suite pass.
broken=0
cap=1000
while [ $cap -lt 1010 ]; do
  out="$TMP/ctx-$cap.md"
  ( cd "$REPO" && MULTI_CONTEXT_MAX_FILE_BYTES=$cap bash "$TREE/scripts/collect-context.sh" ) >"$out" 2>/dev/null
  [ "$(valid_utf8 "$out")" = yes ] || broken=$(( broken + 1 ))
  cap=$(( cap + 1 ))
done
say "no cap produces broken UTF-8" "$broken" "0"

echo "== truncation still happens =="
out="$TMP/ctx-cut.md"
( cd "$REPO" && MULTI_CONTEXT_MAX_FILE_BYTES=1001 bash "$TREE/scripts/collect-context.sh" ) >"$out" 2>/dev/null
say "cut file is marked truncated" "$(grep -c 'truncated' "$out" | tr -d ' ')" "1"
say "cut file is much smaller than the source" \
  "$([ "$(wc -c <"$out")" -lt 3000 ] && echo yes || echo no)" "yes"

echo "== an uncut file is untouched =="
SMALL="$TMP/small"
mkdir -p "$SMALL"
( cd "$SMALL" && git init -q && git config user.email t@t && git config user.name t )
printf 'правило про кириллицу\n' >"$SMALL/CLAUDE.md"
out="$TMP/ctx-small.md"
( cd "$SMALL" && bash "$TREE/scripts/collect-context.sh" ) >"$out" 2>/dev/null
say "short file survives whole" "$(grep -c 'правило про кириллицу' "$out" | tr -d ' ')" "1"
say "short file is valid UTF-8" "$(valid_utf8 "$out")" "yes"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
