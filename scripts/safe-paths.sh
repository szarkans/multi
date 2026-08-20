#!/usr/bin/env bash
# Decide WHICH paths the external reviewers are allowed to see — by name only,
# before anybody reads a single byte of content.
#
#   safe-paths.sh --diff uncommitted
#   safe-paths.sh --diff "main...HEAD"
#   safe-paths.sh --paths "src/auth.py src/session.py"
#   safe-paths.sh --self-test
#
# Why this exists, and why it runs FIRST:
#
#   The reviewers are told to find the change themselves — and the honest way
#   to describe an uncommitted change includes untracked files, because a
#   brand-new file is the change. But "untracked" is also where a working tree
#   keeps the things that were never meant to leave the machine: .env.local, a
#   deploy key somebody dropped in the repo root, a service-account JSON, this
#   plugin's own providers.env. Handing an external model the instruction
#   "list the working tree and read what you find" hands it those too, and by
#   the time any filter could look at the content, the content is already in
#   somebody else's prompt.
#
#   So the order is inverted: names first, content never here. This script
#   looks at path names, drops the ones that match a deny rule, and prints an
#   explicit allow-list. The reviewers then get that list through --paths and
#   are told not to widen it. Nothing is filtered after the fact, because after
#   the fact is too late.
#
# It is deliberately path-only. It does not open files, does not grep for
# high-entropy strings, and does not try to be a secret scanner: a scanner that
# reads content to decide whether content may be read has already lost.
#
# Output (stdout), machine-readable, one item per line:
#
#   allow: <path>
#   withheld: <path> <rule>
#   summary: <n> allowed, <m> withheld
#
# Exit codes: 0 = decided; 2 = usage error or scope could not be resolved.
# Fail-closed: if the scope cannot be resolved, nothing is allowed. An empty
# allow-list is a valid answer and means "do not send anything", never
# "send everything".
set -uo pipefail

DIFF=""; PATHS=""; SELFTEST=0
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --diff) need $# "$1"; DIFF="$2"; shift 2 ;;
    --paths) need $# "$1"; PATHS="$2"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Same guard as the other scripts: a revision starting with "-" is an option to
# git, not a revision.
case "$DIFF" in -*) echo "--diff must be a revision, not an option: $DIFF" >&2; exit 2 ;; esac

# --- the deny rules ------------------------------------------------------
#
# Matched with `case` against the full path and against the basename, so a
# rule catches both `.env.local` and `config/.env.local`. Kept as literal
# globs rather than one regex on purpose: this list is meant to be read and
# extended by whoever is looking at their own repo, not decoded.
#
# The allow-listed exceptions come first — .env.example is the file whose
# entire job is to be committed and shared, and withholding it would hide a
# real part of the change for no gain.
deny_rule() { # deny_rule <path> -> prints the rule that killed it, or nothing
  local p="$1" b
  b="${p##*/}"

  case "$b" in
    .env.example|.env.sample|.env.template|.env.dist|env.example) return 0 ;;
  esac

  case "$b" in
    .env|.env.*|*.env)                 echo "env-file";     return 0 ;;
    .netrc|.pgpass|.htpasswd|.npmrc)   echo "credentials";  return 0 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*) echo "ssh-key";  return 0 ;;
    *_rsa|*_dsa|*_ecdsa|*_ed25519)     echo "ssh-key";      return 0 ;;
    *.pem|*.key|*.p8|*.p12|*.pfx|*.jks|*.keystore) echo "key-material"; return 0 ;;
    *secret*|*Secret*|*SECRET*)        echo "secret-name";  return 0 ;;
    *credential*|*Credential*)         echo "credentials";  return 0 ;;
    *service-account*|*serviceaccount*) echo "service-account"; return 0 ;;
    *.sqlite|*.sqlite3|*.db|*.dump)    echo "local-data";    return 0 ;;
  esac

  case "$p" in
    .ssh/*|*/.ssh/*)         echo "ssh-dir";     return 0 ;;
    .aws/*|*/.aws/*)         echo "cloud-creds"; return 0 ;;
    .gnupg/*|*/.gnupg/*)     echo "gpg-dir";     return 0 ;;
    .docker/config.json|*/.docker/config.json) echo "registry-auth"; return 0 ;;
    .claude/multi/*|*/.claude/multi/*) echo "plugin-keys";  return 0 ;;
  esac

  return 0
}

# --- collecting the scope ------------------------------------------------
# Names only. `git diff --name-only` and `git ls-files` never open a file.
collect() {
  local files=""
  if [ -n "$DIFF" ]; then
    case "$DIFF" in
      uncommitted)
        files="$( { git diff --name-only;
                    git diff --cached --name-only;
                    git ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
        ;;
      *)
        files="$(git diff --name-only "$DIFF" -- 2>/dev/null)" \
          || files="$(git show --name-only --format="" "$DIFF" -- 2>/dev/null)" \
          || return 1
        ;;
    esac
  fi

  if [ -n "$PATHS" ]; then
    local arr=() narrowed="" f p
    read -r -a arr <<<"$PATHS"
    if [ -n "$files" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        for p in "${arr[@]}"; do
          case "$f" in "$p"|"$p"/*) narrowed="$narrowed$f"$'\n'; break ;; esac
        done
      done <<<"$files"
      files="$(printf '%s' "$narrowed")"
    else
      files="$( { git ls-files -- "${arr[@]}" 2>/dev/null; printf '%s\n' "${arr[@]}"; } | sort -u )"
    fi
  fi

  printf '%s' "$files"
}

decide() {
  local files allowed=0 withheld=0 f rule
  files="$(collect)" || {
    # Unresolvable scope. Say so and allow nothing — an unreadable range must
    # not degrade into "review the whole working tree".
    echo "summary: 0 allowed, 0 withheld (scope unresolved: ${DIFF:-$PATHS})"
    return 2
  }

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rule="$(deny_rule "$f")"
    if [ -n "$rule" ]; then
      echo "withheld: $f $rule"
      withheld=$(( withheld + 1 ))
    else
      echo "allow: $f"
      allowed=$(( allowed + 1 ))
    fi
  done <<<"$files"

  echo "summary: $allowed allowed, $withheld withheld"
  return 0
}

# --- self-test -----------------------------------------------------------
#
# Two assertions, and the negative one alone would not be enough: a script
# that withholds EVERYTHING also passes "the .env was withheld". So the test
# checks both directions — the secret is gone AND the ordinary source file is
# still there. Break the deny list and the first fails; break collection and
# the second fails.
self_test() {
  local tmp rc=0 out
  tmp="$(mktemp -d)" || { echo "self-test: cannot create tmpdir" >&2; return 1; }
  (
    cd "$tmp" || exit 1
    git init -q .
    mkdir -p src
    printf 'print("hi")\n' > src/app.py
    printf 'TOKEN=live-value\n' > .env.local
    printf 'x\n' > deploy_rsa
    git add -A >/dev/null 2>&1
  ) || { rm -rf "$tmp"; echo "self-test: fixture failed" >&2; return 1; }

  out="$(cd "$tmp" && DIFF=uncommitted PATHS="" "$SELF" --diff uncommitted)"

  printf '%s\n' "$out" | grep -q '^allow: src/app\.py$' || {
    echo "self-test FAIL: ordinary source file was not allowed through"; rc=1; }
  printf '%s\n' "$out" | grep -q '^withheld: \.env\.local env-file$' || {
    echo "self-test FAIL: .env.local reached the allow list"; rc=1; }
  printf '%s\n' "$out" | grep -q '^withheld: deploy_rsa ssh-key$' || {
    echo "self-test FAIL: private key reached the allow list"; rc=1; }
  printf '%s\n' "$out" | grep -q '^allow: \.env\.local$' && {
    echo "self-test FAIL: .env.local appears in allow"; rc=1; }

  rm -rf "$tmp"
  [ "$rc" = 0 ] && echo "self-test OK — 3 checks (1 positive control, 2 negative)"
  return "$rc"
}

SELF="$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"

if [ "$SELFTEST" = "1" ]; then
  self_test
  exit $?
fi

[ -n "$DIFF" ] || [ -n "$PATHS" ] || { echo "usage: safe-paths.sh --diff <spec> | --paths \"<paths>\" | --self-test" >&2; exit 2; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 2; }

decide
exit $?
