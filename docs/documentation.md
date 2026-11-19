# TrueNAS homelab toolkit — Documentation

🇬🇧 **English** · 🇮🇹 [Italiano](documentazione.md)

This is the complete guide: installation, every setting of every script, how they work inside, restoring a backup, common problems, security and development. The short version is in the [README](../README.md).

- [Overview](#overview)
- [Installation](#installation)
- [lan-guard](#lan-guard)
- [heartbeat](#heartbeat)
- [storage-status](#storage-status)
- [system-backup](#system-backup)
- [Security](#security)
- [Development](#development)

# Overview

Four independent scripts for a TrueNAS SCALE / Community Edition server at home. Each one solves one problem, has its own settings file and can be used without the others.

| Script | Problem it solves | Runs |
|---|---|---|
| `lan-guard` | Docker opens app ports to the whole home LAN, and the usual firewall rules do not stop it | at boot and every 5 minutes |
| `heartbeat` | Monitoring on the NAS goes silent when the NAS goes down | every minute |
| `storage-status` | Pool health, scrubs, disk errors, cloud space and snapshots are spread over the UI, and dashboards should not hold admin credentials | every 30 minutes |
| `system-backup` | TrueNAS keeps its configuration copies on the NAS itself, and a snapshot of a running database is not a reliable backup | every night, verified weekly |

## Requirements

- **TrueNAS 25.10** (the version they are tested on). On another version each script still runs, and prints a warning when started by hand.
- **Root**: the scripts run from TrueNAS cron jobs and init scripts as root.
- **A data pool** for the toolkit folder: the boot pool is replaced on every TrueNAS update.
- Nothing to install: they use what TrueNAS already has (bash 5, python 3.11, `midclt`, `iptables`, `docker`, `rclone`, `curl`, `flock`). Outside TrueNAS, `system-backup` also runs on any Linux machine with Docker, without its TrueNAS parts.

## Folder layout

```
install.sh                    creates the cron jobs and the init script
toolkit.conf.example          settings shared by several scripts
lan-guard/                    lan-guard.sh, lan-guard.conf.example
heartbeat/                    heartbeat.sh, heartbeat.conf.example
storage-status/               storage-status.py, storage-status.conf.example
system-backup/                system-backup.sh, system-backup-verify.sh, common.sh, system-backup.conf.example
examples/system-backup.sh     the original backup script, kept as a reference
docs/                         this guide, the storage-status JSON schema
tests/                        tests run by CI
```

Each script reads its settings from a `.conf` file next to it, created from the `.conf.example`. The files are plain shell variables (`storage-status.conf` uses the same `KEY="value"` lines).

# Installation

## Get the toolkit

```bash
git clone https://github.com/EmaLau/truenas-homelab-toolkit.git /mnt/tank/toolkit
cd /mnt/tank/toolkit
```

Replace `/mnt/tank` with one of your pools. To update later: `git pull`, then run `./install.sh` again.

## Create the settings files

Copy the example of each script you want and edit it:

```bash
cp lan-guard/lan-guard.conf.example lan-guard/lan-guard.conf
cp heartbeat/heartbeat.conf.example heartbeat/heartbeat.conf && chmod 600 heartbeat/heartbeat.conf
cp storage-status/storage-status.conf.example storage-status/storage-status.conf     # optional
cp system-backup/system-backup.conf.example system-backup/system-backup.conf && chmod 600 system-backup/system-backup.conf
```

Files that contain URLs working as passwords (heartbeat, system-backup, `toolkit.conf`) must be readable by root only: the scripts warn when they are not. Each section below lists the settings of its script.

## install.sh

`install.sh` creates the jobs through the TrueNAS middleware, the same way as *System → Advanced → Cron Jobs* and *Init/Shutdown Scripts* in the web UI.

```bash
./install.sh --dry-run                    # show what would be created, change nothing
./install.sh                              # every script that has its settings file (storage-status: if storage-status.conf exists)
./install.sh heartbeat storage-status     # only these
./install.sh --disabled                   # create the jobs switched off, to review them in the UI
./install.sh --uninstall                  # remove the jobs created by install.sh
```

| Script | Job created | Command |
|---|---|---|
| lan-guard | init script, post-init | `lan-guard.sh apply` |
| lan-guard | cron, every 5 minutes | `lan-guard.sh apply` |
| heartbeat | cron, every minute | `heartbeat.sh` |
| storage-status | cron, every 30 minutes | `storage-status.py` |
| system-backup | cron, every day at 03:00 | `system-backup.sh` |
| system-backup-verify | cron, Sundays at 05:00 | `system-backup-verify.sh --restore` |

The schedules can be changed in `toolkit.conf` (`SCHEDULE_HEARTBEAT="*/2 * * * *"` and so on, see below). Pick times that do not overlap with jobs that update or restart apps.

How it behaves:

- **Its own jobs are recognised by their description** (`truenas-homelab-toolkit: <script>`). Running it again changes nothing if everything is in place, and updates the jobs if something differs, for example the path after moving the folder. It never adds a second copy.
- **Jobs made by hand are reported, not touched.** If another job already runs `lan-guard.sh` or `heartbeat.sh`, `install.sh` prints a warning: remove that job, or the script runs twice.
- **Settings are checked first**: a script named on the command line without its settings file, or an invalid `lan-guard.conf`, stops it before any change.
- It warns when the TrueNAS version has not been tested and when the folder is not under `/mnt`.
- Cron jobs run as root, with standard output hidden and errors shown, so TrueNAS reports failures.

You can also create the jobs by hand in the web UI with the commands in the table (prefix them with `/bin/bash` or `/usr/bin/python3` and the full path).

## Shared settings: toolkit.conf

`toolkit.conf`, next to `install.sh` (another path: `TOOLKIT_CONF=/path`), holds the settings that several scripts share:

| Setting | Used by |
|---|---|
| `NOTIFY_URL`, `NOTIFY_FORMAT`, `NOTIFY_TOKEN`, `NOTIFY_CHAT_ID` | heartbeat, system-backup |
| `KUMA_URL` | heartbeat |
| `SCHEDULE_LAN_GUARD`, `SCHEDULE_HEARTBEAT`, `SCHEDULE_STORAGE_STATUS`, `SCHEDULE_SYSTEM_BACKUP`, `SCHEDULE_SYSTEM_BACKUP_VERIFY` | install.sh: the schedule of each job (5 cron fields) |

A value left **empty** in a script's own file falls back to `toolkit.conf`; a value set there wins. The notification settings go together: if a script sets its own `NOTIFY_URL`, it also uses its own format, token and chat.

# lan-guard

## Why

A TrueNAS app is published on a host port, and Docker makes that port reachable from every device on the home network. Admin dashboards (Uptime Kuma, Scrutiny, Dozzle…) often have no login or a weak one, so a guest's phone, a smart TV or a compromised device can open them. If you only use these tools over a VPN, the LAN does not need them at all.

## How it works

The obvious fix, a rule in the `INPUT` chain, does not work: Docker rewrites the destination of the packet (DNAT) **before** the filter sees it. A packet for `NAS:30002` becomes a packet for `container:3001`, and from then on it goes through `FORWARD`, not `INPUT`, with the original port gone.

lan-guard uses two things:

- **The `DOCKER-USER` chain**, which Docker reserves for user rules: it is evaluated before Docker's own rules and Docker never flushes it.
- **Conntrack**, which remembers the original destination of every connection: `--ctorigdstport 30002` matches the connection even after the rewrite.

For every port it creates, in a chain `LAN-GUARD` called from `DOCKER-USER`:

```
-A LAN-GUARD -i eth0 -m conntrack --ctstate NEW --ctproto tcp --ctorigdstport 30002 -j DROP
```

and the same rule in a chain `LAN-GUARD-IN` called from `INPUT`, for connections that reach the NAS directly (for example `docker-proxy` over IPv6). Only **new** connections from the **LAN interface** are dropped: replies, VPN traffic (another interface), localhost, SSH and the web UI are untouched, so it cannot lock you out.

Rules are rebuilt in a temporary chain and swapped in, so there is never a moment without them. TrueNAS and Docker rebuild their firewall rules when apps or the system restart: that is why it runs at boot and every 5 minutes.

## Settings (lan-guard.conf)

| Setting | Default | Meaning |
|---|---|---|
| `LAN_IF` | `eth0` | The interface connected to the home LAN (`ip -br link`) |
| `PORTS` | none, required | TCP ports to block from the LAN, e.g. `(30001 30002)` |
| `ALLOW` | empty | LAN addresses still allowed on a port: `("30002=192.168.1.20" "30001=192.168.1.0/28" "30002=fd00::20")` |
| `LOG_DROPS` | `no` | `yes`: write dropped connections to the kernel log |
| `LOG_LIMIT` | `5/min` | At most this many log lines per port and chain |

- Ports must be numbers from 1 to 65535.
- `ALLOW` takes IPv4 or IPv6 addresses, with an optional prefix; the port must be in `PORTS`. Host names are refused, because the firewall would resolve them only once. Allowed connections leave the lan-guard chains with `RETURN` and continue through the normal Docker and INPUT rules.
- Logged lines start with `lan-guard-drop:`: read them with `dmesg | grep lan-guard-drop` or `journalctl -k -g lan-guard-drop`.

Every value is checked before the firewall is touched: an invalid one stops the script with a message.

## Commands

| Command | What it does |
|---|---|
| `lan-guard.sh dry-run` | Prints, in `iptables-save` syntax, exactly the rules `apply` would create, for IPv4 and IPv6. Needs neither root nor iptables |
| `lan-guard.sh` or `lan-guard.sh apply` | Creates or rebuilds the rules (idempotent) |
| `lan-guard.sh status` | Shows the rules with their hit counters |
| `lan-guard.sh off` | Removes every rule and chain (rollback) |

## Checking that it works

1. `lan-guard.sh dry-run`: the ports and the interface are the ones you expect.
2. `lan-guard.sh`, then open a blocked port **from a device on the home Wi-Fi, with the VPN off**: it must not load.
3. `lan-guard.sh status`: the counters of that port are above 0.
4. With the VPN on, the same address opens: VPN traffic is not filtered, by design.

## Warnings and limits

- **TCP only**: UDP ports stay reachable from the LAN.
- **IPv6**: filtered when `ip6tables` works; otherwise IPv6 is skipped with a warning.
- **The interface is matched by name.** If `LAN_IF` does not exist (a typo, a new network card, a bridge created later) the rules match nothing and the ports are open again. `apply` and `status` warn when the interface is missing; counters that stay at 0 are another hint.
- **Docker must use iptables.** The rules for containers live in `DOCKER-USER`, which Docker uses with its default iptables backend (on TrueNAS `iptables` writes nftables rules, which is fine). With Docker stopped or switched to its nftables backend, nothing jumps to `DOCKER-USER`: `apply` and `status` warn when `FORWARD` does not jump there.

## Common problems

- **The port still opens.** Are you on the VPN? Is `LAN_IF` the interface the LAN traffic arrives on (`ip -br addr`)? Does `status` print a warning about the interface or `DOCKER-USER`?
- **"ip6tables not available, IPv6 is not filtered".** IPv6 is disabled in the kernel or `ip6tables` is missing: IPv4 is still filtered.
- **I want to undo everything.** `lan-guard.sh off`, and remove the jobs (`./install.sh --uninstall lan-guard`).

# heartbeat

## Why

A monitoring tool that runs on the NAS cannot tell you the NAS is down: when it freezes, loses power or drops off the internet, the monitor goes silent with it, and silence looks like "all good". heartbeat turns the check around: the NAS proves every minute that it is alive, and a service **outside** raises the alarm when the proof stops arriving.

## The parts

Every part is optional and is skipped when its settings are empty; with none configured the script stops with an error.

1. **NAS alive → heartbeat service.** A GET to `HEALTHCHECKS_URL` every minute: [Healthchecks.io](https://healthchecks.io) (free plan, or self-hosted on another machine), or any service that takes a GET as a ping (for example an Uptime Kuma push URL on another machine). Set the check period to 1 minute and a grace time of a few minutes.
2. **Tailscale state → Uptime Kuma.** Pushes `up` when the Tailscale container reports `Running`, `down` otherwise, to a Kuma *push* monitor.
3. **Your own checks → Uptime Kuma.** Any command: exit code 0 is up, anything else (or a timeout) is down.
4. **Notifications → ntfy or a webhook**, when part 2 or 3 changes state.

## Settings (heartbeat.conf)

| Setting | Default | Meaning |
|---|---|---|
| `HEALTHCHECKS_URL` | empty | Ping URL of the heartbeat service |
| `KUMA_URL` | empty | Base address of Uptime Kuma, e.g. `http://127.0.0.1:3001` |
| `KUMA_TOKEN` | empty | Token of the push monitor for the Tailscale state (the last part of `/api/push/<token>`) |
| `TAILSCALE_CONTAINER` | `ix-tailscale-tailscale-1` | Name of the Tailscale container (`docker ps`) |
| `CHECKS` | empty | Checks, one per entry: `"NAME|KUMA_TOKEN|COMMAND"` |
| `CHECK_TIMEOUT` | `20` | Seconds each check may run |
| `NOTIFY_URL` | empty | ntfy topic URL or webhook URL |
| `NOTIFY_FORMAT` | `ntfy` | `ntfy`, `json` or `telegram` |
| `NOTIFY_TOKEN` | empty | Sent as `Authorization: Bearer <token>` (ntfy, json) |
| `NOTIFY_CHAT_ID` | empty | Telegram only: the chat that receives the messages |

`KUMA_URL` and the notification settings can come from `toolkit.conf`.

## Setting up Uptime Kuma

In Kuma, add a monitor of type **Push** for each thing to watch (Tailscale, each check). Kuma shows a URL like `http://kuma:3001/api/push/AbC123?status=up&msg=OK&ping=`: the base address goes into `KUMA_URL` (once), the token (`AbC123`) into `KUMA_TOKEN` or into the check. Set the heartbeat interval to 60 seconds, like the cron job.

## Checks

```bash
CHECKS=(
  "pools|<kuma-token>|zpool status -x | grep -q 'all pools are healthy'"
  "nextcloud||curl -fsS -m 5 -o /dev/null http://127.0.0.1:30027/status.php"
)
```

- `NAME`: letters, digits, dot, dash, underscore. It names the check in the notifications and in the state folder.
- `KUMA_TOKEN`: the push monitor of the check; leave it empty to use the check only for notifications.
- `COMMAND`: runs with bash, as root, with `CHECK_TIMEOUT` seconds. The first line of its output becomes the message (`exit 3: <first line>` when it fails, `timed out after 20s` on timeout); Kuma also receives the time it took.

## Notifications

Only on changes: when a check goes down and when it comes back up, never every minute. The last state of each check is kept in `state/` next to the script; on the very first run only checks that are down notify.

- `NOTIFY_FORMAT=ntfy` posts the message as text to the topic URL (`https://ntfy.sh/<topic>` or your own ntfy server), with a title (`<host>: <check> is DOWN` or `is back up`), a tag and a priority (high when down).
- `NOTIFY_FORMAT=json` posts to any webhook:

```json
{"host": "nas", "check": "nextcloud", "status": "down", "msg": "exit 7: ...", "time": 1795102290}
```

- `NOTIFY_FORMAT=telegram` sends the title and the message through a Telegram bot: `NOTIFY_URL="https://api.telegram.org/bot<token>/sendMessage"` (the token of the bot, from @BotFather) and the chat in `NOTIFY_CHAT_ID`. The URL contains the token: keep the file `chmod 600`.

Notifications only report checks: a NAS that is off cannot notify anything, which is what part 1 is for.

## Behaviour

- **One run at a time**: when the previous run is still going (slow checks), the next one is skipped with a message.
- A **`PAUSE`** file in the folder suspends everything, for example during maintenance.
- Requests that fail (network down, Kuma restarting) print a warning, never stop the other parts.

## Common problems

- **Kuma shows the monitor as down while the NAS is fine.** The push interval in Kuma is shorter than the cron interval, or `KUMA_URL` is not reachable from the NAS (`curl` it by hand).
- **No notification.** Notifications are sent only on changes; check `state/<name>` and the URL with a `curl -d test <NOTIFY_URL>`.
- **"is readable by other users".** `chmod 600 heartbeat.conf`.

# storage-status

## Why

The numbers that tell you a NAS is heading for trouble are on different pages of the TrueNAS UI, and cloud space is not shown at all. Dashboards such as Homepage can show a JSON file, but they should not hold an admin API key for TrueNAS or your cloud credentials. storage-status collects everything as root, every half hour, into one file that any dashboard or bot can read without credentials.

## What it collects

Through the TrueNAS middleware (`midclt`), `zfs` and `rclone`:

- status, size, free space and health of every pool, with the space level (`OK`, `LOW`, `CRITICAL`);
- the last scrub or resilver of every pool: state, errors, progress while running, age;
- every disk of every pool, with its role (data, cache, log, spare, special, dedup), status and read, write and checksum errors;
- used and free space of the cloud credentials that report it: **OneDrive and Google Drive** (other providers are skipped);
- the last run of every cloud sync task: state, start, end, error;
- space used by snapshots in every pool;
- for every dataset with a periodic snapshot task: number of snapshots, the newest one and its age, space used. Snapshots are matched with the task's naming schema, so manual snapshots do not count; several tasks on the same dataset are merged.

## Settings (storage-status.conf)

All optional. The file can be elsewhere with `STORAGE_STATUS_CONF=/path`; environment variables with the same names override it.

| Setting | Default | Meaning |
|---|---|---|
| `STORAGE_STATUS_OUT` | `/var/tmp/storage_status.json` | Where to write the JSON file |
| `PROMETHEUS_OUT` | empty (off) | Also write Prometheus metrics to this file |
| `WARN_PCT` | `20` | Free space (percent) below which pools and cloud storage are `LOW` |
| `CRIT_PCT` | `10` | Free space below which they are `CRITICAL` |

The thresholds must satisfy `0 ≤ CRIT_PCT < WARN_PCT ≤ 100`.

## The JSON file

Written atomically (a dashboard never reads half a file), readable by everyone. Values are raw numbers: bytes, Unix timestamps, hours; formatting is up to the dashboard. The full format is in [storage-status.schema.json](storage-status.schema.json), and a complete example, with a degraded pool during a resilver and an offline pool, in [storage-status.example.json](../tests/storage-status.example.json).

| Key | Content |
|---|---|
| `schema_version` | 1. Goes up only on incompatible changes; new fields can appear without it |
| `generated_at`, `generated_epoch` | When the data was collected (ISO 8601 with the time zone, and Unix time) |
| `thresholds` | `warn_pct` and `crit_pct` in use |
| `errors` | Sections that failed, with the message; empty when all went well |
| `pools` | By pool name: `status`, `size`, `free`, `used`, `free_pct`, `space_status`, `healthy`, `scan`, `disks` |
| `cloud` | By credential name: `provider`, `status` (`OK`, `LOW`, `CRITICAL`, `ERROR`), `total`, `used`, `free`, `free_pct` |
| `cloud_sync` | By task description: `credential`, `direction`, `enabled`, `state`, `started`, `finished`, `age_hours`, `error` |
| `snapshot_space` | By pool: bytes used by snapshots |
| `snapshots` | By dataset: `tasks`, `recursive`, `count`, `bytes`, `last`, `last_epoch`, `age_hours` |

Things to know: ZFS keeps only the most recent scan, so `scan` is the last scrub **or** resilver. TrueNAS keeps only the last job of a cloud sync task, so while a sync runs, `state` is `RUNNING` and the result of the previous one is not visible.

## Errors

Each section (`pools`, `cloud`, `cloud_sync`, `snapshots`) is collected on its own. If one fails (a middleware call times out, `zfs` errors), the file is still written with the other sections complete, the failed one is listed in `errors`, and the script exits with status 1, so the cron job reports it.

## Prometheus metrics

With `PROMETHEUS_OUT` set, the same data is also written as gauges for node_exporter's *textfile* collector: point `PROMETHEUS_OUT` to a file in the folder given to `--collector.textfile.directory`.

| Metric | Labels |
|---|---|
| `storage_status_generated_timestamp_seconds` | |
| `storage_status_section_ok` (1 if the section was collected) | `section` |
| `storage_status_pool_size_bytes`, `_pool_free_bytes` | `pool` |
| `storage_status_pool_healthy`, `_pool_online` (1 or 0) | `pool` |
| `storage_status_pool_scan_errors`, `_pool_scan_end_timestamp_seconds`, `_pool_scan_running` | `pool` |
| `storage_status_disk_online` | `pool`, `disk` |
| `storage_status_disk_errors` | `pool`, `disk`, `type` (read, write, checksum) |
| `storage_status_cloud_up`, `_cloud_total_bytes`, `_cloud_used_bytes`, `_cloud_free_bytes` | `credential`, `provider` |
| `storage_status_cloudsync_success`, `_cloudsync_running`, `_cloudsync_finished_timestamp_seconds` | `task`, `id` |
| `storage_status_snapshot_space_bytes` | `pool` |
| `storage_status_snapshots`, `_snapshots_bytes`, `_snapshot_last_timestamp_seconds` | `dataset` |

Example alerts: `storage_status_pool_healthy == 0`, `time() - storage_status_snapshot_last_timestamp_seconds > 2 * 86400`, `storage_status_cloudsync_success == 0`.

## Cloud tokens

To read the cloud space, the credentials of TrueNAS are passed to `rclone about` in a temporary config file (mode 600, deleted afterwards). rclone refreshes OAuth tokens when they expire, and OneDrive rotates its refresh tokens: a refreshed token that is thrown away would sooner or later break the cloud sync tasks. So, like TrueNAS after a cloud sync, the script saves a refreshed token back to the credential (`cloudsync.credentials.update`), and only if it looks valid.

## Common problems

- **A section is in `errors`.** Run the script by hand: the message is also printed on stderr.
- **A cloud credential is missing.** Only OneDrive and Google Drive report their space.
- **The dashboard shows old data.** Check `generated_at` and that the cron job runs; the file is replaced only at the end of a run.

# system-backup

## Why

The copies TrueNAS keeps of its own configuration stay on the NAS, so they are lost along with it, and a ZFS snapshot of a running database folder is not guaranteed to restore. A useful nightly backup has to dump the databases properly, save the configuration with its secret seed, and prove that each piece can be read back.

## What a backup contains

Each run creates `BACKUP_DIR/YYYY-MM-DD_HH-MM-SS`, with only the parts you configure:

```
truenas/      truenas-config-<version>-<date>.tar   config.save with the secret seed
app-configs/  app-query.json, <app>.json             TrueNAS app settings
databases/    pg-<container>-<db>.dump               pg_dump -Fc
              pg-<container>-globals.sql             roles
              mysql-<container>-<db>.sql.gz          mariadb-dump / mysqldump
archives/     <name>.tar.gz                          one per ARCHIVES entry
metadata/     manifest.json, SHA256SUMS
```

Every part is checked as it is made:

- the configuration must contain the database (`freenas-v1.db`) and the secret seed (`pwenc_secret`): without the seed, a restored configuration loses every stored password;
- a PostgreSQL dump must be a `pg_dump` archive and pass `pg_restore --list`;
- a MariaDB/MySQL dump must end with the end-of-dump marker;
- an archive must list every required file.

Work happens in an `.incomplete-*` folder renamed only at the end, so a half-made backup never looks complete. Files are readable by root only.

## Settings (system-backup.conf)

| Setting | Default | Meaning |
|---|---|---|
| `BACKUP_DIR` | none, required | Folder that holds the backups (existing, absolute) |
| `MIN_FREE_GB` | `5` | Stop before starting if less space is free |
| `KEEP_DAILY` | `30` | Keep every backup of the last N days |
| `KEEP_MONTHLY` | `12` | Then the first backup of each of the last N months |
| `TRUENAS_CONFIG` | `yes` | Back up the TrueNAS configuration |
| `APP_CONFIGS` | empty | App names whose `app.config` is saved, or `("*")` for every app |
| `PG_DUMPS` | empty | PostgreSQL databases: `("CONTAINER USER DATABASE" ...)` |
| `MYSQL_DUMPS` | empty | MariaDB/MySQL databases, same format |
| `ARCHIVES` | empty | Folder archives (see below) |
| `APP_START_TIMEOUT` | `300` | Seconds to wait for a stopped app to be running again |
| `APP_IDLE_CHECKS` | empty | Wait before stopping a busy app: `("APP|COMMAND|MAX_WAIT_SECONDS" ...)` (see below) |
| `HEALTHCHECKS_URL` | empty | Pinged at the start, on success and on failure |
| `NOTIFY_URL`, `NOTIFY_FORMAT`, `NOTIFY_TOKEN`, `NOTIFY_CHAT_ID` | empty, `ntfy`, empty, empty | Notifications, as in heartbeat (ntfy, json or telegram) |
| `NOTIFY_ON` | `failure` | `failure` or `always` (warnings are always notified) |
| `PG_IMAGE`, `MYSQL_IMAGE` | `postgres:18-alpine`, `mariadb:11` | Images used by `--restore` |

Container names are in `docker ps` (TrueNAS apps are `ix-<app>-<service>-1`).

## Databases

- **PostgreSQL**: `pg_dump -Fc` runs inside the container, in one transaction, so the dump is consistent while the app keeps running. The roles are saved too (`pg_dumpall --globals-only`).
- **MariaDB/MySQL**: `mariadb-dump` (or `mysqldump`) with `--single-transaction --routines --triggers --events`. The password is read **inside the container** from its own environment (`MARIADB_ROOT_PASSWORD`/`MYSQL_ROOT_PASSWORD` for root, `MARIADB_PASSWORD`/`MYSQL_PASSWORD` otherwise), so it never appears on the NAS command line or in the log.

The same database cannot be listed twice.

## Archives

One entry per archive: `"NAME|APPS_TO_STOP|PATHS|EXCLUDES|REQUIRED"`, lists separated by commas.

```bash
ARCHIVES=(
  "monitoring|uptime-kuma|/mnt/Apps/UptimeKuma||/mnt/Apps/UptimeKuma/data/kuma.db"
  "live||/mnt/Apps/Nextcloud/html/config,?/mnt/Apps/Extra|*/cache|/mnt/Apps/Nextcloud/html/config/config.php"
)
```

| Field | Meaning |
|---|---|
| `NAME` | File name of the archive (letters, digits, `.`, `_`, `-`) |
| `APPS_TO_STOP` | TrueNAS apps stopped while **this** archive is made, then started again, only if they were running. Empty: the archive is made live |
| `PATHS` | Absolute paths. A leading `?` makes a path optional (skipped with a warning when missing); a missing path without `?` fails the backup |
| `EXCLUDES` | tar patterns, matched against paths without the leading `/` (e.g. `*/cache`) |
| `REQUIRED` | Paths that must end up in the archive, or the backup fails |

**Busy apps.** Some apps should not be stopped in the middle of their work (a copy, a transcode). `APP_IDLE_CHECKS` gives such an app a command that exits 0 when it can be stopped, for example a script that asks the app's API whether it is copying:

```bash
APP_IDLE_CHECKS=("auto-disk-copy|/mnt/tank/scripts/autodiskcopy-idle.sh|2700")
```

Before stopping the app, the command is tried every minute for at most `MAX_WAIT_SECONDS`. If the app is still busy, it is **not stopped**: its archive is made live, with a warning in the log and in the notification.

Stop the apps whose data must be consistent on disk (an SQLite database, for example) and archive the rest live; in a live archive, files changing while read are a warning, not an error. Stopped apps are started again **even when the backup fails**, and the backup fails if one of them is not running again after `APP_START_TIMEOUT` seconds. Paths are stored without the leading `/`, so an archive extracts relative to the folder you choose. Paths cannot contain commas.

## Retention

After each successful backup: every backup of the last `KEEP_DAILY` days is kept; of older ones, the first backup of each of the last `KEEP_MONTHLY` months; a folder containing a `.keep` file is never removed (`touch BACKUP_DIR/<date>/.keep`). The backup just made is never removed.

## Alerts and status

- `HEALTHCHECKS_URL` receives `/start` at the beginning, the plain URL on success and `/fail` on failure. With a daily period in Healthchecks, a backup that never ran raises an alert too.
- `NOTIFY_URL` receives a message on failure; on success only with warnings, or always with `NOTIFY_ON="always"`.
- `BACKUP_DIR/status/last_run.json` describes the last run (`status`, `timestamp`, `version` of TrueNAS, size, duration, warnings or exit code), `last_success.json` the last successful one, `last_verify.json` the last verification. `BACKUP_DIR/latest` points to the newest backup, and the log is in `BACKUP_DIR/logs/`.
- Only one backup runs at a time.

## Verifying a backup

```bash
system-backup-verify.sh                       # the latest backup
system-backup-verify.sh --restore             # also restore the databases
system-backup-verify.sh /mnt/tank/SystemBackups/2026-11-19_03-00-00
```

It checks the checksums and the manifest, extracts the TrueNAS configuration and runs SQLite's integrity check on its database and checks the secret seed, parses every app setting, reads every archive to the end (a damaged block anywhere is found) and checks the format of every dump.

With `--restore`, each database is restored into a **throwaway container without network** (`PG_IMAGE`, `MYSQL_IMAGE`) and its tables are counted. The images must be at least the version of your databases: `pg_restore` reads older dumps, not newer ones. Nothing outside a temporary folder in `BACKUP_DIR` is changed, and the containers are removed at the end. A failure exits with status 1 and is notified.

## Restoring

The backup is made of ordinary files; restoring is done by hand, part by part.

- **TrueNAS configuration**: on a fresh TrueNAS of the same version or newer, *System → General Settings → Manage Configuration → Upload File*, and choose `truenas/truenas-config-*.tar`. The archive includes the secret seed, so stored passwords keep working.
- **PostgreSQL**: stop the app that uses the database (not its database container), then:

  ```bash
  docker exec -i ix-nextcloud-postgres-1 pg_restore -U nextcloud -d nextcloud --clean --if-exists < databases/pg-ix-nextcloud-postgres-1-nextcloud.dump
  ```

- **MariaDB/MySQL**: `zcat databases/mysql-<container>-<db>.sql.gz | docker exec -i <container> sh -c 'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" <db>'`.
- **Archives**: stop the apps, then `tar -xzf archives/<name>.tar.gz -C /` puts the files back where they were (or `-C /some/folder` to look at them first).
- **App settings** (`app-configs/`): reference for recreating an app with the same settings.

Run `system-backup-verify.sh --restore` regularly (`install.sh` schedules it weekly): it is the proof that these steps will work.

## Without TrueNAS

With `TRUENAS_CONFIG="no"`, no `APP_CONFIGS` and no apps to stop, `system-backup.sh` needs neither `midclt` nor TrueNAS: it backs up databases in Docker containers and folders on any Linux machine.

## The original example

`examples/system-backup.sh` is the script these came from, kept as a reference. It is tied to one homelab and includes app-specific logic (waiting for an app to be idle before stopping it, Telegram notifications); use `system-backup/` instead.

## Common problems

- **"midclt not found".** The TrueNAS parts are on and the script is not on TrueNAS.
- **An app is not running after the backup.** The log says which one; `APP_START_TIMEOUT` may be too short for a slow app.
- **"another backup is running".** A previous run is still going (or crashed while holding the lock: the lock is released when its process ends).
- **`--restore` fails on PostgreSQL.** `PG_IMAGE` is older than the database that made the dump.

# Security

- **The scripts run as root.** Read them before installing; each is short and does only what its section describes.
- **Settings files hold secrets** (Healthchecks and Kuma URLs, notification tokens): keep them `chmod 600`; the scripts warn when other users can read them. Do not commit them: `.gitignore` excludes `*.conf`.
- **Backups contain secrets**: the TrueNAS secret seed, app settings, database dumps. Backup folders are created readable by root only; keep `BACKUP_DIR` private, and encrypt it if it leaves the NAS.
- **lan-guard cannot lock you out**: it filters only new connections from the LAN interface to the ports you list, never SSH, the web UI or the VPN.
- **Network**: the scripts contact only the addresses you configure (Healthchecks, Kuma, ntfy or webhook, the cloud providers through rclone). `system-backup-verify.sh --restore` pulls the database images, and runs the restore containers without network.
- **Database passwords** are never passed on the NAS command line: MariaDB/MySQL dumps read them inside the container.

Security problems: see [SECURITY.md](../SECURITY.md).

# Development

## Layout

Each script is self-contained: bash for lan-guard, heartbeat and system-backup (`common.sh` holds what `system-backup.sh` and `system-backup-verify.sh` share), Python for storage-status (standard library only). They target what TrueNAS 25.10 has: bash 5 and Python 3.11.

## Tests

| Test | What it checks | How it runs |
|---|---|---|
| `tests/lan-guard-test.sh` | Rules on a real firewall: apply, idempotence, dry-run, allowlist, logging, warnings, rollback, no ip6tables | in a throwaway container with `NET_ADMIN` (refuses to run elsewhere) |
| `tests/heartbeat-test.sh` | Pushes, checks, timeouts, notifications on changes, settings, lock, `toolkit.conf` | fake `curl` and `docker`, nothing is sent |
| `tests/storage-status-test.py` | JSON, Prometheus file, thresholds, cloud tokens, failing sections, settings | fake `midclt`, `zfs` and `rclone` answering from `tests/storage-status.fixtures.json` |
| `tests/system-backup-test.sh` | Configuration, app settings, stopping and restarting apps, failures, retention, lock, verify | fake `midclt` and `curl` |
| `tests/system-backup-restore-test.sh` | Real backup and `--restore` of PostgreSQL 16 and MariaDB 11 | needs Docker |
| `tests/install-test.sh` | Create, update after moving the folder, jobs made by hand, uninstall | fake middleware |

```bash
docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro alpine:3.20 \
  sh -c 'apk add -q iptables ip6tables bash && bash /src/tests/lan-guard-test.sh'
bash tests/heartbeat-test.sh
python3 tests/storage-status-test.py
bash tests/system-backup-test.sh
bash tests/system-backup-restore-test.sh
bash tests/install-test.sh
```

The bash tests need GNU tools (on macOS, run them in a `python:3.13-alpine` container with `bash coreutils tar findutils util-linux`, as the comments at the top of each test show).

## Continuous integration

Every push and pull request runs, on GitHub Actions: syntax checks, shellcheck, ruff (lint and format), Python 3.11 compilation, the schema check of the example JSON, all the tests above, and the build of this documentation as HTML pages.

## Documentation

This guide exists in English (`docs/documentation.md`) and Italian (`docs/documentazione.md`), like the README. `docs/web/build.sh <folder>` turns both into standalone HTML pages with pandoc (`docs-en.html`, `docs-it.html`). When something changes, update both languages and the [changelog](../CHANGELOG.md).

Contributions: see [CONTRIBUTING.md](../CONTRIBUTING.md).
