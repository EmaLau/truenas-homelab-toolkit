#!/bin/bash
# Heartbeat: run as root from cron every minute. Independent, optional parts:
#
#  1. NAS alive -> ping a heartbeat URL (HEALTHCHECKS_URL: Healthchecks.io or any
#     service that takes a GET as a ping). If the NAS shuts down or loses
#     internet the pings stop, and the alert comes from outside the NAS.
#  2. Tailscale state -> Uptime Kuma push monitor (KUMA_URL + KUMA_TOKEN): up when
#     the Tailscale container reports "Running", down otherwise.
#  3. Generic checks (CHECKS): any command, exit code 0 = up, each with its own
#     Kuma push monitor.
#  Notifications (NOTIFY_URL): when a check of part 2 or 3 goes down or comes
#  back up, send one message to ntfy or to a webhook (JSON).
#
# Settings: heartbeat.conf next to this script (see heartbeat.conf.example).
# A part without its settings is skipped. Pause everything: create a PAUSE file here.
set -u
DIR="$(dirname "$(readlink -f "$0")")"
CONF="$DIR/heartbeat.conf"
STATE_DIR="$DIR/state"

HEALTHCHECKS_URL=""
KUMA_URL=""
KUMA_TOKEN=""
TAILSCALE_CONTAINER="ix-tailscale-tailscale-1"
CHECKS=()            # "NAME|KUMA_TOKEN|COMMAND"; the token can be empty
CHECK_TIMEOUT=20     # seconds per check command
NOTIFY_URL=""        # ntfy topic URL (https://ntfy.sh/<topic>) or webhook URL
NOTIFY_FORMAT="ntfy" # ntfy (plain text + headers), json, or telegram
NOTIFY_TOKEN=""      # optional: sent as "Authorization: Bearer <token>"
NOTIFY_CHAT_ID=""    # telegram only: the chat that receives the messages

[ -f "$DIR/PAUSE" ] && exit 0
# Warn about untested TrueNAS versions, only when run by hand (not from cron).
if [ -t 2 ] && [ -r /etc/version ] && [[ "$(cat /etc/version)" != 25.10* ]]; then
  echo "heartbeat: TrueNAS $(cat /etc/version) has not been tested (tested: 25.10)" >&2
fi
load() {   # source a settings file, warning if other users can read its secrets
  if [ -n "$(find "$1" -perm /044 2>/dev/null)" ]; then
    echo "heartbeat: $1 is readable by other users, run: chmod 600 $1" >&2
  fi
  # shellcheck source=/dev/null
  . "$1"
}
# Shared settings (toolkit.conf in the toolkit folder): an empty value in
# heartbeat.conf means "use the shared one". Notification settings go together.
TK="${TOOLKIT_CONF:-$DIR/../toolkit.conf}"
TK_NOTIFY=("" "" "" "") TK_KUMA_URL=""
if [ -f "$TK" ]; then
  load "$TK"
  TK_NOTIFY=("$NOTIFY_URL" "$NOTIFY_FORMAT" "$NOTIFY_TOKEN" "$NOTIFY_CHAT_ID") TK_KUMA_URL="$KUMA_URL"
  NOTIFY_URL="" NOTIFY_FORMAT="ntfy" NOTIFY_TOKEN="" NOTIFY_CHAT_ID="" KUMA_URL=""
fi
[ -f "$CONF" ] && load "$CONF"
if [ -z "$NOTIFY_URL" ] && [ -n "${TK_NOTIFY[0]}" ]; then
  NOTIFY_URL="${TK_NOTIFY[0]}" NOTIFY_FORMAT="${TK_NOTIFY[1]:-ntfy}" NOTIFY_TOKEN="${TK_NOTIFY[2]}" NOTIFY_CHAT_ID="${TK_NOTIFY[3]}"
fi
[ -n "$KUMA_URL" ] || KUMA_URL="$TK_KUMA_URL"

fail() { echo "heartbeat: $*" >&2; exit 1; }
for C in ${CHECKS[@]+"${CHECKS[@]}"}; do
  IFS='|' read -r name token cmd <<<"$C"
  [[ "$C" == *"|"*"|"* && "$name" =~ ^[A-Za-z0-9._-]+$ && -n "$cmd" ]] \
    || fail "invalid CHECKS entry '$C' in $CONF: use \"NAME|KUMA_TOKEN|COMMAND\" (NAME: letters, digits, . _ -)"
  [ -z "$token" ] || [ -n "$KUMA_URL" ] || fail "check '$name' has a Kuma token but KUMA_URL is empty"
done
[[ "$CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "CHECK_TIMEOUT must be a number of seconds"
case "$NOTIFY_FORMAT" in ntfy|json|telegram) ;; *) fail "NOTIFY_FORMAT must be ntfy, json or telegram" ;; esac
[ "$NOTIFY_FORMAT" != telegram ] || [ -z "$NOTIFY_URL" ] || [ -n "$NOTIFY_CHAT_ID" ] \
  || fail "NOTIFY_FORMAT=telegram needs NOTIFY_CHAT_ID"
TAILSCALE=no
[ -n "$KUMA_URL" ] && [ -n "$KUMA_TOKEN" ] && TAILSCALE=yes
if [ -z "$HEALTHCHECKS_URL" ] && [ "$TAILSCALE" = no ] && [ "${#CHECKS[@]}" -eq 0 ]; then
  fail "nothing to do, set HEALTHCHECKS_URL, KUMA_URL + KUMA_TOKEN and/or CHECKS in $CONF"
fi

# One run at a time: slow checks must not pile up when cron starts the next one.
exec 9>"$DIR/.heartbeat.lock"
if ! flock -n 9; then
  echo "heartbeat: previous run still in progress, skipping" >&2
  exit 0
fi

# Send one message to NOTIFY_URL. Arguments: check name, up|down, message.
notify() {
  local host title auth=()
  host="$(hostname)"
  [ -n "$NOTIFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NOTIFY_TOKEN")
  if [ "$2" = down ]; then title="$host: $1 is DOWN"; else title="$host: $1 is back up"; fi
  if [ "$NOTIFY_FORMAT" = telegram ]; then
    curl -fsS -m 10 -o /dev/null --data-urlencode "chat_id=$NOTIFY_CHAT_ID" \
      --data-urlencode "text=$title
$3" "$NOTIFY_URL"
  elif [ "$NOTIFY_FORMAT" = json ]; then
    python3 -c 'import json,sys,time; print(json.dumps({"host": sys.argv[1], "check": sys.argv[2], "status": sys.argv[3], "msg": sys.argv[4], "time": int(time.time())}))' \
      "$host" "$1" "$2" "$3" \
      | curl -fsS -m 10 -o /dev/null ${auth[@]+"${auth[@]}"} -H "Content-Type: application/json" --data-binary @- "$NOTIFY_URL"
  else
    curl -fsS -m 10 -o /dev/null ${auth[@]+"${auth[@]}"} -H "Title: $title" \
      -H "Tags: $([ "$2" = down ] && echo rotating_light || echo white_check_mark)" \
      -H "Priority: $([ "$2" = down ] && echo high || echo default)" \
      --data-binary "$3" "$NOTIFY_URL"
  fi || echo "heartbeat: notification for $1 failed" >&2
}

# Report the state of a check. Arguments: name, Kuma token (or empty), up|down,
# message, duration in ms (or empty).
report() {
  local name="$1" token="$2" status="$3" msg="$4" ping="$5" last=""
  if [ -n "$token" ]; then
    curl -fsS -m 10 -o /dev/null -G "${KUMA_URL%/}/api/push/$token" \
      --data-urlencode "status=$status" --data-urlencode "msg=$msg" \
      ${ping:+--data-urlencode "ping=$ping"} \
      || echo "heartbeat: Uptime Kuma push for $name failed" >&2
  fi
  [ -n "$NOTIFY_URL" ] || return 0
  # Notify on changes only; a first run notifies only if the check is down.
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/$name" ] && last="$(cat "$STATE_DIR/$name")"
  if [ "$status" != "${last:-up}" ]; then notify "$name" "$status" "$msg"; fi
  echo "$status" >"$STATE_DIR/$name"
}

# Part 1: NAS alive
if [ -n "$HEALTHCHECKS_URL" ]; then
  curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_URL" \
    || echo "heartbeat: heartbeat ping failed" >&2
fi

# Part 2: Tailscale state -> Uptime Kuma
if [ "$TAILSCALE" = yes ]; then
  state=$(docker exec "$TAILSCALE_CONTAINER" tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null)
  [ -z "$state" ] && state="container unreachable"
  if [ "$state" = "Running" ]; then st=up; else st=down; fi
  report tailscale "$KUMA_TOKEN" "$st" "Tailscale $state" ""
fi

# Part 3: generic checks
for C in ${CHECKS[@]+"${CHECKS[@]}"}; do
  IFS='|' read -r name token cmd <<<"$C"
  start=${EPOCHREALTIME//[.,]/}
  out=$(timeout "$CHECK_TIMEOUT" bash -c "$cmd" 2>&1 </dev/null)
  rc=$?
  ms=$(( (${EPOCHREALTIME//[.,]/} - start) / 1000 ))   # EPOCHREALTIME: bash 5, microseconds
  first=$(printf '%s\n' "$out" | head -n 1 | cut -c1-100)
  if [ "$rc" -eq 0 ]; then
    report "$name" "$token" up "${first:-OK}" "$ms"
  elif [ "$rc" -eq 124 ]; then
    report "$name" "$token" down "timed out after ${CHECK_TIMEOUT}s" "$ms"
  else
    report "$name" "$token" down "exit $rc${first:+: $first}" "$ms"
  fi
done
exit 0
