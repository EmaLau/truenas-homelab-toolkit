#!/bin/bash
# Heartbeat: run as root from cron every minute. Two independent, optional parts:
#
#  1. NAS alive -> ping Healthchecks.io (HEALTHCHECKS_URL). If the NAS shuts down
#     or loses internet the pings stop, and the alert comes from Healthchecks,
#     outside the NAS.
#  2. Tailscale state -> Uptime Kuma push monitor (KUMA_URL + KUMA_TOKEN): up when
#     the Tailscale container reports "Running", down otherwise.
#
# Settings: heartbeat.conf next to this script (see heartbeat.conf.example).
# A part without its settings is skipped. Pause everything: create a PAUSE file here.
set -u
DIR="$(dirname "$(readlink -f "$0")")"
CONF="$DIR/heartbeat.conf"

HEALTHCHECKS_URL=""
KUMA_URL=""
KUMA_TOKEN=""
TAILSCALE_CONTAINER="ix-tailscale-tailscale-1"

[ -f "$DIR/PAUSE" ] && exit 0
if [ -f "$CONF" ]; then
  # The file holds secret URLs: warn if other users can read it.
  if [ -n "$(find "$CONF" -perm /044 2>/dev/null)" ]; then
    echo "heartbeat: $CONF is readable by other users, run: chmod 600 $CONF" >&2
  fi
  # shellcheck source=/dev/null
  . "$CONF"
fi
if [ -z "$HEALTHCHECKS_URL" ] && { [ -z "$KUMA_URL" ] || [ -z "$KUMA_TOKEN" ]; }; then
  echo "heartbeat: nothing to do, set HEALTHCHECKS_URL and/or KUMA_URL + KUMA_TOKEN in $CONF" >&2
  exit 1
fi

# Part 1: Healthchecks
if [ -n "$HEALTHCHECKS_URL" ]; then
  curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_URL" \
    || echo "heartbeat: Healthchecks ping failed" >&2
fi

# Part 2: Tailscale state -> Uptime Kuma
if [ -n "$KUMA_URL" ] && [ -n "$KUMA_TOKEN" ]; then
  state=$(docker exec "$TAILSCALE_CONTAINER" tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null)
  [ -z "$state" ] && state="container unreachable"
  if [ "$state" = "Running" ]; then st=up; else st=down; fi
  curl -fsS -m 10 -o /dev/null -G "${KUMA_URL%/}/api/push/$KUMA_TOKEN" \
    --data-urlencode "status=$st" --data-urlencode "msg=Tailscale $state" \
    || echo "heartbeat: Uptime Kuma push failed" >&2
fi
exit 0
