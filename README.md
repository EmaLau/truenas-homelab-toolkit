# TrueNAS homelab toolkit

<p align="center"><img src="docs/cover.svg" width="400" alt=""></p>

🇬🇧 **English** · 🇮🇹 [Italiano](README.it.md)

**Small, independent scripts for running TrueNAS at home.** Keep admin dashboards off the home LAN, get an alert when the NAS itself goes down, put pool health and backups on one dashboard, and make nightly backups that are proven to restore. Extracted from a homelab where they run every day.

[![CI](https://github.com/EmaLau/truenas-homelab-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/EmaLau/truenas-homelab-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![TrueNAS](https://img.shields.io/badge/TrueNAS-25.10-0095d5)
![Bash](https://img.shields.io/badge/bash-5-4EAA25?logo=gnubash&logoColor=white)
![Python](https://img.shields.io/badge/python-3.11+-3776AB?logo=python&logoColor=white)

| Script | What it does | Runs |
|---|---|---|
| [`lan-guard`](#lan-guard) | Blocks admin-only app ports from the home LAN (IPv4 and IPv6), without touching SSH, the web UI or VPN access | at boot and every 5 min |
| [`heartbeat`](#heartbeat) | Pings an external monitor so you hear when the NAS is down; runs your own checks and notifies ntfy or a webhook | every minute |
| [`storage-status`](#storage-status) | Pool health and space, scrubs, disk errors, cloud space, cloud sync results and snapshots in one JSON file, or as Prometheus metrics | every 30 min |
| [`system-backup`](#system-backup) | TrueNAS configuration, app settings, PostgreSQL and MariaDB databases and app folders, with checksums, retention and a verify script that restores the databases | every night |

The complete guide, with every setting, how each script works inside, restoring a backup and common problems, is the **[documentation](docs/documentation.md)**.

## Install

The scripts run as root on TrueNAS (tested on 25.10). Clone the repository on a **data pool** (the boot pool is replaced on updates), create the settings files of the scripts you want from their examples, then let `install.sh` create the cron jobs and the init script through the TrueNAS middleware:

```bash
git clone https://github.com/EmaLau/truenas-homelab-toolkit.git /mnt/tank/toolkit
cd /mnt/tank/toolkit
cp lan-guard/lan-guard.conf.example lan-guard/lan-guard.conf    # and so on, then edit them
./install.sh --dry-run      # show what would be created
./install.sh                # create or update the jobs
```

`install.sh` recognises its own jobs, so running it again (after an update, or after moving the folder) updates them instead of adding copies; it reports jobs you made by hand for the same scripts, which would otherwise run twice. `--disabled` creates the jobs switched off, `--uninstall` removes them. Settings shared by several scripts (notifications, Uptime Kuma) can go once in `toolkit.conf`. Details: [Installation](docs/documentation.md#installation).

## lan-guard

Docker opens published app ports to every device on the LAN, and an ordinary firewall rule does not stop it: Docker rewrites the destination before `INPUT` sees the packet. `lan-guard.sh` drops new connections from the LAN interface to the ports you list, in the `DOCKER-USER` chain, matching the original port with conntrack. VPN traffic, SSH and the TrueNAS UI are not touched, so it cannot lock you out.

```bash
lan-guard.sh dry-run   # print the rules, change nothing
lan-guard.sh           # apply (idempotent)
lan-guard.sh status    # rules and hit counters
lan-guard.sh off       # remove everything
```

Optional: LAN addresses still allowed on a port (`ALLOW`) and rate-limited logging of drops. It warns when the interface is missing or Docker no longer uses `DOCKER-USER`. TCP only. [More](docs/documentation.md#lan-guard).

## heartbeat

A monitor on the NAS cannot tell you the NAS is down. `heartbeat.sh` turns it around: every minute it pings [Healthchecks](https://healthchecks.io) or any heartbeat service, which alerts you from outside when the pings stop. It can also push the Tailscale state and your own checks (any command: exit code 0 is up) to Uptime Kuma, and send one message to ntfy or a webhook when a check goes down or comes back up. [More](docs/documentation.md#heartbeat).

## storage-status

Collects, as root, what the TrueNAS UI spreads over several pages: pool status, space and health, the last scrub or resilver, error counters of every disk, space of OneDrive and Google Drive credentials, the last run of every cloud sync task and the state of every snapshot task. Writes it to one JSON file ([schema](docs/storage-status.schema.json)) that a dashboard can read without credentials, and optionally as Prometheus metrics for node_exporter. A failing part never stops the others. [More](docs/documentation.md#storage-status).

## system-backup

`system-backup.sh` makes a nightly backup driven by one settings file: the TrueNAS configuration with its secret seed, app settings, hot PostgreSQL and MariaDB/MySQL dumps checked right away, and folder archives that stop only their own apps, restarting them even on failure. Checksums, a manifest, retention (daily, then monthly) and alerts through Healthchecks, ntfy or a webhook.

`system-backup-verify.sh --restore` proves a backup works: it checks every file and restores every database into a throwaway container. [More](docs/documentation.md#system-backup).

## Development

Every script is tested in CI: lan-guard against a real firewall in a container, the backup end to end against real PostgreSQL and MariaDB, the rest with fake TrueNAS commands. See [Development](docs/documentation.md#development) and [CONTRIBUTING.md](CONTRIBUTING.md); security problems go to [SECURITY.md](SECURITY.md).

Changes are in the [changelog](CHANGELOG.md), plans in the [roadmap](ROADMAP.md). License: [MIT](LICENSE).
