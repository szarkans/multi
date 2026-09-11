#!/usr/bin/env bash
# Blocks while the Claude account is too close to its usage limit to start
# another run. A run started near the limit dies halfway -- one built-in review
# with the full test suite has been measured eating 20 points of the 5-hour
# window -- and a dead run grades as a miss. So this waits; it exits 0 only
# when there is room. A caller that sees any other exit (the gate was killed)
# must treat it as "not cleared", never as permission.
#
#   usage-gate.sh            (env: GATE_FIVE_HOUR=75 GATE_SEVEN_DAY=70 GATE_POLL=600)
#
# Reads the same endpoint the status line uses. Anything it cannot read -- a
# network error, a rejected token, a response without the windows it expects --
# is a reason to wait, never a 0%: launching blind is how the night of
# 2026-09-11 was lost.
set -uo pipefail
FIVE="${GATE_FIVE_HOUR:-75}"; SEVEN="${GATE_SEVEN_DAY:-70}"; POLL="${GATE_POLL:-600}"
CRED="${GATE_CRED:-$HOME/.claude/.credentials.json}"
URL="${GATE_URL:-https://api.anthropic.com/api/oauth/usage}"
LOG="${GATE_LOG:-/dev/null}"
say() { [ "${GATE_QUIET:-0}" = 1 ] && return; command -v tg-say >/dev/null && printf '%s\n' "$1" | tg-say --plain >/dev/null 2>&1; }

read_usage() {
  python3 - "$CRED" "$FIVE" "$SEVEN" "$URL" <<'PY' 2>/dev/null
import json, sys, urllib.request, urllib.error, datetime
cred, five, seven, url = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
tok = json.load(open(cred))["claudeAiOauth"]["accessToken"]
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok, "anthropic-beta": "oauth-2025-04-20"})
try:
    d = json.load(urllib.request.urlopen(req, timeout=15))
except urllib.error.HTTPError as e:
    print("AUTH" if e.code in (401, 403) else "ERR http %d" % e.code)
    sys.exit()
def win(k):
    w = d[k]                                   # a missing window is unreadable, not 0%
    u = w["utilization"]
    if isinstance(u, bool) or not isinstance(u, (int, float)):
        raise ValueError(k)
    try:                                       # display only: never worth failing the read
        loc = datetime.datetime.fromisoformat(str(w.get("resets_at")).replace("Z", "+00:00")).astimezone().strftime("%d.%m %H:%M")
    except ValueError:
        loc = "?"
    return float(u), loc
f, fat = win("five_hour"); s, sat = win("seven_day")
if f >= five:    print("PAUSE 5ч-окно %.0f%% (порог %.0f%%), сброс %s" % (f, five, fat))
elif s >= seven: print("PAUSE недельное окно %.0f%% (порог %.0f%%), сброс %s" % (s, seven, sat))
else:            print("GO 5ч %.0f%%, неделя %.0f%%" % (f, s))
PY
}

paused=""; fails=0; refreshed=0
while :; do
  st="$(read_usage)"
  case "$st" in
    GO*)
      [ -n "$paused" ] && { echo "$(date '+%F %T') resume: $st" >> "$LOG"; say "Прогон продолжен: $st"; }
      exit 0 ;;
    PAUSE*)
      fails=0; refreshed=0
      if [ "$paused" != "${st%%,*}" ]; then
        echo "$(date '+%F %T') $st" >> "$LOG"; echo "$st" >&2
        [ -z "$paused" ] && say "Прогон на паузе: ${st#PAUSE }"
        paused="${st%%,*}"
      fi ;;
    AUTH)
      # The access token lives about eight hours and only a running claude
      # refreshes it -- and a long pause runs none. Ask claude to, once per
      # streak: `auth status` costs nothing; a one-word haiku call is the fallback.
      if [ "$refreshed" = 0 ]; then
        refreshed=1; echo "$(date '+%F %T') token rejected, asking claude to refresh it" >> "$LOG"
        timeout 60 claude auth status >/dev/null 2>&1 < /dev/null
        [ "$(read_usage)" = AUTH ] && timeout 180 claude -p ok --model haiku --setting-sources "" >/dev/null 2>&1 < /dev/null
        continue
      fi
      fails=$((fails+1)); echo "$(date '+%F %T') token still rejected ($fails)" >> "$LOG"
      [ "$fails" = 3 ] && say "Прогон стоит: токен Claude не принимается даже после обновления. Нужен вход (claude auth login). Жду, вслепую не запускаю."
      ;;
    *)
      fails=$((fails+1)); echo "$(date '+%F %T') usage unreadable ($fails): ${st:-no answer}" >> "$LOG"
      [ "$fails" = 3 ] && say "Прогон стоит: не могу прочитать загрузку Claude (сеть? формат ответа?). Жду, вслепую не запускаю."
      ;;
  esac
  sleep "$POLL"
done
