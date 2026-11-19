# TrueNAS homelab toolkit

<p align="center"><img src="docs/cover.svg" width="400" alt=""></p>

[![CI](https://github.com/EmaLau/truenas-homelab-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/EmaLau/truenas-homelab-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Small scripts extracted from a running TrueNAS homelab, where they run every day. See the [changelog](CHANGELOG.md) and [the roadmap](ROADMAP.md).

A collection of small, independent scripts for running a TrueNAS SCALE / Community Edition box at home. Each one solves one problem and can be used on its own.

| Script | What it does | Runs from |
|---|---|---|
| [`lan-guard`](#lan-guard) | Blocks admin-only app ports from the home LAN, in IPv4 and IPv6, without touching SSH, the web UI or VPN access | init script + cron every 5 min |
| [`heartbeat`](#heartbeat) | Pings an external monitor every minute, so you get an alert when the NAS itself goes down | cron every minute |
| [`storage-status`](#storage-status) | Writes pool usage, cloud storage usage and snapshot age/size to one JSON file for dashboards | cron every 30 min |
| [`examples/system-backup.sh`](#system-backup-example) | A nightly backup of the TrueNAS configuration, app databases and app folders, with checksums and retention | cron nightly |

All scripts run as root from TrueNAS cron jobs or init scripts (System → Advanced). Keep them on a data pool, not on the boot pool.

## lan-guard

Apps published by Docker are reachable from the whole LAN, usually without a login. `lan-guard.sh` drops **new** connections that arrive on the LAN interface for a list of ports, while VPN (e.g. Tailscale), localhost, SSH and the TrueNAS UI keep working: it cannot lock you out.

- Docker DNATs published ports before filtering, so the rules live in `DOCKER-USER` and match the original port with conntrack; a second chain in `INPUT` covers connections that reach `docker-proxy` directly (e.g. over IPv6).
- Rules are rebuilt in a temporary chain and swapped, so there is never a moment without them.

```bash
cp lan-guard/lan-guard.conf.example lan-guard/lan-guard.conf   # set LAN_IF and PORTS
lan-guard.sh          # apply (idempotent)
lan-guard.sh status   # rules and hit counters
lan-guard.sh off      # remove everything
```

Add it as a **post-init** script and as a cron job every 5 minutes: TrueNAS and Docker can rebuild their firewall rules.

Limits to know:

- **TCP only.** UDP ports stay reachable from the LAN.
- **IPv4 and IPv6.** If `ip6tables` is missing or IPv6 is disabled in the kernel, IPv6 is skipped with a warning on stderr.
- **The interface is matched by name.** If `LAN_IF` does not exist (typo, a new network card, a bridge created later), the rules match nothing and the ports are open again. `lan-guard.sh` and `lan-guard.sh status` warn when the interface is missing; the hit counters in `status` staying at 0 is another hint. Check `LAN_IF` after any network change (`ip -br link`).
- Test from a device on the LAN, not over the VPN: VPN traffic is not filtered by design.

## heartbeat

Every monitoring tool that runs on the NAS goes silent when the NAS goes down. `heartbeat.sh` runs every minute from cron and has two independent parts. Both are optional: a part without its settings is skipped.

```bash
cp heartbeat/heartbeat.conf.example heartbeat/heartbeat.conf
chmod 600 heartbeat/heartbeat.conf    # the URLs inside work as passwords
```

**1. NAS alive → Healthchecks.** Pings an external service such as [Healthchecks.io](https://healthchecks.io) (free plan, or self-hosted elsewhere). When the NAS shuts down or loses internet, the pings stop and Healthchecks alerts you, from outside the NAS. Set `HEALTHCHECKS_URL` to the check's ping URL and the check period to 1 minute.

**2. Tailscale state → Uptime Kuma.** Pushes `up` or `down` to an Uptime Kuma *push* monitor, depending on whether the Tailscale container reports `Running`. Useful when Tailscale is how you reach the NAS from outside. Set `KUMA_URL` (base address of Kuma) and `KUMA_TOKEN` (last part of the push URL); `TAILSCALE_CONTAINER` defaults to `ix-tailscale-tailscale-1`, the name TrueNAS gives the Tailscale app.

The script warns on stderr if `heartbeat.conf` is readable by other users, and exits with an error if no part is configured. A `PAUSE` file in the folder suspends it (e.g. during maintenance).

## storage-status

Collects, through the TrueNAS middleware (`midclt`), `zfs` and `rclone`:

- status, size and free space of every pool;
- used and free space of the cloud credentials that report it: **OneDrive and Google Drive** only, other providers are skipped;
- space used by snapshots in every pool;
- for every dataset with a periodic snapshot task: number of snapshots, the newest one and its age, space used. Snapshots are matched with the task's naming schema, so manual snapshots are not counted.

The result is a single JSON file (`$STORAGE_STATUS_OUT`, default `/var/tmp/storage_status.json`), written atomically, that a dashboard or a bot can read without credentials. Values are raw numbers (bytes, Unix timestamps, hours): formatting is up to the dashboard. The format is described by [`docs/storage-status.schema.json`](docs/storage-status.schema.json):

```json
{
 "schema_version": 1,
 "generated_at": "2026-11-19T16:31:30+01:00",
 "pools": {
  "tank": {"status": "ONLINE", "size": 27986006900736, "free": 27234230513664, "used": 751776387072, "free_pct": 97}
 },
 "cloud": {
  "Microsoft OneDrive": {"id": 1, "provider": "onedrive", "status": "OK",
                         "total": 1239098064896, "used": 24910810317, "free": 1214187254579, "free_pct": 98}
 },
 "snapshot_space": {"tank": 8137539432, "boot-pool": 227655680},
 "snapshots": {
  "tank/data": {"tasks": [2, 3], "recursive": false, "count": 39, "bytes": 8136843792,
                "last": "auto-2026-11-19_02-00", "last_epoch": 1795050000, "age_hours": 14.53}
 }
}
```

Cloud status is `OK`, `LOW` (under 20 % free), `CRITICAL` (under 10 %) or `ERROR` (with an `error` field).

**Cloud tokens.** To read the cloud space, the script passes the TrueNAS cloud credentials to `rclone about` through a temporary config file (mode 600, deleted afterwards). rclone refreshes OAuth tokens when they expire; like TrueNAS after a cloud sync, the script saves the refreshed token back to the credential (`cloudsync.credentials.update`), so the stored one never goes stale.

## system-backup example

`examples/system-backup.sh` is the nightly backup of the original homelab, **kept as a reference, not a drop-in script**: it names that system's apps and folders, and it stops and restarts some apps. Everything tied to that system is in one *Site-specific settings* block at the top (apps to stop, `app.config` list, PostgreSQL containers, folders to archive, required files); the per-app stop and restart logic needs adapting too. The pool that holds the backups is set with `DATA_POOL` (default `tank`), the folder with the app data with `APPS_ROOT` (default `/mnt/Apps`). What it shows:

- `config.save` of TrueNAS, verified (it must contain the database and the secret seed);
- hot `pg_dump -Fc` of PostgreSQL databases running in app containers, verified with `pg_restore --list`;
- `app.config` of every app;
- archives of app folders, taken while apps run, and stopping only the apps that need it, after checking that they are idle;
- SHA-256 checksums of everything, a manifest, and retention (30 daily, 12 monthly, `.keep` folders forever);
- work in an `.incomplete-*` folder, renamed only at the end.

## Tests

`tests/lan-guard-test.sh` checks lan-guard against a real firewall inside a throwaway container (it refuses to run anywhere else):

```bash
docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro alpine:3.20 \
  sh -c 'apk add -q iptables ip6tables bash && bash /src/tests/lan-guard-test.sh'
```

## Roadmap

What is missing before the first public release, and the features planned after it, are in [ROADMAP.md](ROADMAP.md).

## License

[MIT](LICENSE). Changes are listed in the [changelog](CHANGELOG.md).
