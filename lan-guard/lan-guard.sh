#!/bin/bash
# LAN guard: blocks NEW TCP connections arriving from the home LAN interface (LAN_IF)
# to the admin-only app ports. VPN interfaces (e.g. tailscale0), localhost and the
# TrueNAS UI/SSH (80, 443, 22) are not touched, so this cannot lock out the console or SSH.
# Only TCP is filtered: UDP ports stay reachable from the LAN. Optional: LAN
# addresses allowed on a port (ALLOW), rate-limited logging of drops (LOG_DROPS).
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
ALLOW=()          # "PORT=ADDRESS[/PREFIX]", IPv4 or IPv6
LOG_DROPS="no"    # yes: log dropped connections to the kernel log
LOG_LIMIT="5/min" # at most this many log lines per port and chain
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
    for A in ${ALLOW[@]+"${ALLOW[@]}"}; do
        P="${A%%=*}" ADDR="${A#*=}"
        if ! [[ "$A" == *=* && " ${PORTS[*]} " == *" $P "* ]]; then
            echo "Invalid ALLOW entry '$A' ($CONF): use PORT=ADDRESS with a port listed in PORTS" >&2; exit 1
        fi
        if ! [[ "$ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ || "$ADDR" =~ ^[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]]; then
            echo "Invalid address in ALLOW entry '$A' ($CONF): use an IPv4 or IPv6 address, optionally with /prefix" >&2; exit 1
        fi
    done
    case "$LOG_DROPS" in yes|no) ;; *) echo "LOG_DROPS must be yes or no ($CONF)" >&2; exit 1 ;; esac
    if ! [[ "$LOG_LIMIT" =~ ^[0-9]+/(second|sec|s|minute|min|m|hour|h|day|d)$ ]]; then
        echo "Invalid LOG_LIMIT '$LOG_LIMIT' ($CONF): use e.g. 5/min" >&2; exit 1
    fi
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

# The rules of one chain (fwd or in) for one table, one per line, without the
# "-A CHAIN" part; shared by apply and dry-run. For every port: RETURN for the
# allowed addresses of that IP family, then the optional LOG, then DROP.
# RETURN hands the packet back to DOCKER-USER/INPUT, where it goes on as usual.
chain_rules() {
    local KIND="$1" TABLE="$2" P A ADDR MATCH
    for P in "${PORTS[@]}"; do
        if [ "$KIND" = fwd ]; then
            MATCH="-i $LAN_IF -m conntrack --ctstate NEW --ctproto tcp --ctorigdstport $P"
        else
            MATCH="-i $LAN_IF -p tcp --dport $P -m conntrack --ctstate NEW"
        fi
        for A in ${ALLOW[@]+"${ALLOW[@]}"}; do
            ADDR="${A#*=}"
            [ "${A%%=*}" = "$P" ] || continue
            if [[ "$ADDR" == *:* ]]; then [ "$TABLE" = ip6tables ] || continue
            else [ "$TABLE" = iptables ] || continue; fi
            echo "$MATCH -s $ADDR -j RETURN"
        done
        if [ "$LOG_DROPS" = yes ]; then
            echo "$MATCH -m limit --limit $LOG_LIMIT -j LOG --log-prefix lan-guard-drop:"
        fi
        echo "$MATCH -j DROP"
    done
}

# Append the rules of KIND for TABLE to CHAIN.
fill() {
    local IPT="$1 -w" CHAIN="$2" KIND="$3" RULE
    while read -ra RULE; do $IPT -A "$CHAIN" "${RULE[@]}"; done < <(chain_rules "$KIND" "$1")
}

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
    fill "$1" "$TMP" fwd
    $IPT -I DOCKER-USER 1 -j "$TMP"
    while $IPT -C DOCKER-USER -j "$FWD_CHAIN" 2>/dev/null; do $IPT -D DOCKER-USER -j "$FWD_CHAIN"; done
    $IPT -F "$FWD_CHAIN"
    fill "$1" "$FWD_CHAIN" fwd
    $IPT -I DOCKER-USER 1 -j "$FWD_CHAIN"
    $IPT -D DOCKER-USER -j "$TMP"
    $IPT -F "$TMP"; $IPT -X "$TMP"

    $IPT -F "$IN_CHAIN"
    fill "$1" "$IN_CHAIN" in
    $IPT -C INPUT -j "$IN_CHAIN" 2>/dev/null || $IPT -I INPUT 1 -j "$IN_CHAIN"
}

# What apply ends up with, in iptables-save syntax (the temporary chain used
# for the swap is left out). Needs neither root nor iptables.
dry_run() {
    echo "# $1${2:+ $2} (lan-guard dry-run: nothing is changed)"
    echo "-N $FWD_CHAIN"
    chain_rules fwd "$1" | sed "s/^/-A $FWD_CHAIN /"
    echo "-I DOCKER-USER 1 -j $FWD_CHAIN"
    echo "-N $IN_CHAIN"
    chain_rules in "$1" | sed "s/^/-A $IN_CHAIN /"
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
            echo
            dry_run ip6tables "(if available)" ;;
    *) echo "usage: $0 [apply|off|status|dry-run]" >&2; exit 2 ;;
esac
