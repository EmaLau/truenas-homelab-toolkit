#!/bin/bash
# Tests for lan-guard. Run ONLY inside a throwaway container: it changes the
# firewall of its network namespace and removes ip6tables at the end.
#
#   docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro alpine:3.20 \
#     sh -c 'apk add -q iptables ip6tables bash && bash /src/tests/lan-guard-test.sh'
set -u
[ -f /.dockerenv ] || [ -n "${container:-}" ] || { echo "refusing to run outside a container" >&2; exit 2; }

SRC="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
cp "$SRC/lan-guard/lan-guard.sh" "$W/"
LG="$W/lan-guard.sh"
FAIL=0

conf() { printf 'LAN_IF="%s"\nPORTS=(%s)\n' "$1" "$2" > "$W/lan-guard.conf"; }
count() { $1 -w -S 2>/dev/null | grep -c -- "$2" || true; }
check() {   # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; FAIL=1; fi
}
state() {   # rules per chain and jumps, for one table
    echo "$(count "$1" '^-A LAN-GUARD -i') $(count "$1" '^-A LAN-GUARD-IN -i') $(count "$1" '^-A DOCKER-USER -j LAN-GUARD$') $(count "$1" '^-A INPUT -j LAN-GUARD-IN$')"
}

conf eth0 "30001 30002"
bash "$LG" 2>/dev/null; check "apply: exit code" 0 $?
for T in iptables ip6tables; do check "apply: $T rules and jumps" "2 2 1 1" "$(state $T)"; done
check "apply: TCP only" 0 "$(iptables -w -S | grep -- '-A LAN-GUARD' | grep -vEc -- '-p tcp|--ctproto 6' || true)"

bash "$LG" 2>/dev/null; bash "$LG" 2>/dev/null
for T in iptables ip6tables; do check "apply twice more: $T unchanged" "2 2 1 1" "$(state $T)"; done
check "apply twice more: no temporary chain left" 0 "$(count iptables 'LAN-GUARD-NEW')"

conf eth0 "30003"
bash "$LG" 2>/dev/null
check "new port list replaces the old one" "1 1 1 1" "$(state iptables)"
check "new port list: right port" 1 "$(count iptables 'ctorigdstport 30003')"

check "status: exit code" 0 "$(bash "$LG" status >/dev/null 2>&1; echo $?)"

conf nope0 "30001"
check "missing interface: warning" 1 "$(bash "$LG" 2>&1 >/dev/null | grep -c 'does not exist')"

conf eth0 ""
check "no ports: exit code 1" 1 "$(bash "$LG" >/dev/null 2>&1; echo $?)"

bash "$LG" off >/dev/null; check "off: exit code" 0 $?
for T in iptables ip6tables; do check "off: $T clean" "0 0 0 0" "$(state $T)"; done
check "off: chains deleted" 0 "$(count iptables '^-N LAN-GUARD')"

# Without ip6tables (as when IPv6 tools are missing): warn and filter IPv4 only.
for f in $(command -v ip6tables) /sbin/ip6tables /usr/sbin/ip6tables; do [ -e "$f" ] && rm -f "$f"; done
conf eth0 "30001"
check "no ip6tables: warning" 1 "$(bash "$LG" 2>&1 >/dev/null | grep -c 'IPv6 is not filtered')"
check "no ip6tables: IPv4 rules" "1 1 1 1" "$(state iptables)"
bash "$LG" off >/dev/null; check "no ip6tables: off exit code" 0 $?
check "no ip6tables: off clean" "0 0 0 0" "$(state iptables)"

rm -rf "$W"
if [ "$FAIL" -ne 0 ]; then echo "some lan-guard tests FAILED"; exit 1; fi
echo "all lan-guard tests passed"
