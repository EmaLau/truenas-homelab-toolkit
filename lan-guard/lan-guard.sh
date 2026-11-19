#!/bin/bash
# LAN guard: blocks NEW TCP connections arriving from the home LAN interface (LAN_IF)
# to the admin-only app ports. VPN interfaces (e.g. tailscale0), localhost and the
# TrueNAS UI/SSH (80, 443, 22) are not touched, so this cannot lock out the console or SSH.
# Only TCP is filtered: UDP ports stay reachable from the LAN.
#
#   lan-guard.sh        apply (idempotent; run at boot and every 5 min by cron)
#   lan-guard.sh off    remove all rules (rollback)
#   lan-guard.sh status show rules and hit counters
#   lan-guard.sh dry-run print the rules apply would create, without changing anything
#
# Docker-published ports are DNATed before filtering, so the FORWARD path
# (DOCKER-USER) matches the original port with conntrack; the INPUT path covers
# connections that reach docker-proxy directly (e.g. IPv6).
set -euo pipefail

# Settings: lan-guard.conf next to this script (see lan-guard.conf.example).
LAN_IF="eth0"
PORTS=()
CONF="$(dirname "$(readlink -f "$0")")/lan-guard.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
MODE="${1:-apply}"
if [ "$MODE" = apply ] || [ "$MODE" = dry-run ]; then
    if [ "${#PORTS[@]}" -eq 0 ]; then
        echo "No ports configured: set PORTS in $CONF" >&2; exit 1
    fi
    for P in "${PORTS[@]}"; do
        if ! [[ "$P" =~ ^[0-9]+$ ]] || [ "$P" -lt 1 ] || [ "$P" -gt 65535 ]; then
            echo "Invalid port '$P' in PORTS ($CONF): use numbers from 1 to 65535" >&2; exit 1
        fi
    done
fi
FWD_CHAIN="LAN-GUARD"
IN_CHAIN="LAN-GUARD-IN"

# iptables always; ip6tables only if it is installed and usable (IPv6 can be
# disabled in the kernel), otherwise IPv6 is skipped with a warning.
TABLES=(iptables)
if [ "$MODE" = apply ] || [ "$MODE" = status ]; then
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -w -L INPUT -n >/dev/null 2>&1; then
        TABLES+=(ip6tables)
    else
        echo "lan-guard: ip6tables not available, IPv6 is not filtered" >&2
    fi
fi

# The rules for one port, shared by apply and dry-run.
fwd_rule() { RULE=(-i "$LAN_IF" -m conntrack --ctstate NEW --ctproto tcp --ctorigdstport "$1" -j DROP); }
in_rule() { RULE=(-i "$LAN_IF" -p tcp --dport "$1" -m conntrack --ctstate NEW -j DROP); }

remove() {
    local IPT="$1 -w"
    while $IPT -C DOCKER-USER -j "$FWD_CHAIN" 2>/dev/null; do $IPT -D DOCKER-USER -j "$FWD_CHAIN"; done
    while $IPT -C INPUT -j "$IN_CHAIN" 2>/dev/null; do $IPT -D INPUT -j "$IN_CHAIN"; done
    for C in "$FWD_CHAIN" "$IN_CHAIN" "${FWD_CHAIN}-NEW"; do
        $IPT -F "$C" 2>/dev/null || true
        $IPT -X "$C" 2>/dev/null || true
    done
}

apply() {
    local IPT="$1 -w"
    $IPT -N DOCKER-USER 2>/dev/null || true
    $IPT -N "$FWD_CHAIN" 2>/dev/null || true
    $IPT -N "$IN_CHAIN" 2>/dev/null || true

    # Rebuild into a temporary chain and swap, so there is never a window without rules.
    local TMP="${FWD_CHAIN}-NEW"
    $IPT -N "$TMP" 2>/dev/null || $IPT -F "$TMP"
    for P in "${PORTS[@]}"; do fwd_rule "$P"; $IPT -A "$TMP" "${RULE[@]}"; done
    $IPT -I DOCKER-USER 1 -j "$TMP"
    while $IPT -C DOCKER-USER -j "$FWD_CHAIN" 2>/dev/null; do $IPT -D DOCKER-USER -j "$FWD_CHAIN"; done
    $IPT -F "$FWD_CHAIN"
    for P in "${PORTS[@]}"; do fwd_rule "$P"; $IPT -A "$FWD_CHAIN" "${RULE[@]}"; done
    $IPT -I DOCKER-USER 1 -j "$FWD_CHAIN"
    $IPT -D DOCKER-USER -j "$TMP"
    $IPT -F "$TMP"; $IPT -X "$TMP"

    $IPT -F "$IN_CHAIN"
    for P in "${PORTS[@]}"; do in_rule "$P"; $IPT -A "$IN_CHAIN" "${RULE[@]}"; done
    $IPT -C INPUT -j "$IN_CHAIN" 2>/dev/null || $IPT -I INPUT 1 -j "$IN_CHAIN"
}

# What apply ends up with, in iptables-save syntax (the temporary chain used
# for the swap is left out). Needs neither root nor iptables.
dry_run() {
    echo "# $1 (lan-guard dry-run: nothing is changed)"
    echo "-N $FWD_CHAIN"
    for P in "${PORTS[@]}"; do fwd_rule "$P"; echo "-A $FWD_CHAIN ${RULE[*]}"; done
    echo "-I DOCKER-USER 1 -j $FWD_CHAIN"
    echo "-N $IN_CHAIN"
    for P in "${PORTS[@]}"; do in_rule "$P"; echo "-A $IN_CHAIN ${RULE[*]}"; done
    echo "-I INPUT 1 -j $IN_CHAIN"
}

# Rules match the interface by name: if it does not exist (renamed NIC, typo,
# bridge), they silently match nothing. Warn, but still apply them.
check_interface() {
    if [ ! -e "/sys/class/net/$LAN_IF" ]; then
        echo "lan-guard: interface $LAN_IF does not exist, the rules will block nothing (check LAN_IF in $CONF)" >&2
    fi
}

case "$MODE" in
    apply)  check_interface
            for IPT in "${TABLES[@]}"; do apply "$IPT"; done ;;
    off)    for IPT in iptables ip6tables; do
                if command -v "$IPT" >/dev/null 2>&1; then remove "$IPT"; fi
            done
            echo "LAN guard removed" ;;
    status) check_interface
            for IPT in "${TABLES[@]}"; do
                echo "== $IPT"
                $IPT -w -L "$FWD_CHAIN" -v -n 2>/dev/null || echo "(no $FWD_CHAIN)"
                $IPT -w -L "$IN_CHAIN" -v -n 2>/dev/null || echo "(no $IN_CHAIN)"
            done ;;
    dry-run) check_interface
            dry_run iptables
            echo "# ip6tables: the same rules, if ip6tables is available" ;;
    *) echo "usage: $0 [apply|off|status|dry-run]" >&2; exit 2 ;;
esac
