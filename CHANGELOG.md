# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [2.0.0] — 2026-11-19

Every item of the roadmap after 1.0: a generic, verified backup with MariaDB support, an installer, generic checks and notifications in heartbeat, an allowlist and logging in lan-guard, pool health, cloud sync results and Prometheus output in storage-status, and the documentation in English and Italian. Existing settings files keep working: the new major version marks the new scripts, not a breaking change.

### Added

- `lan-guard`: `ALLOW` lets chosen LAN addresses (IPv4 or IPv6, with an optional prefix) reach a blocked port; they are checked before the firewall is touched.
- `lan-guard`: optional logging of dropped connections (`LOG_DROPS`, `LOG_LIMIT`), rate-limited, with the prefix `lan-guard-drop:`.
- `lan-guard`: `apply` and `status` warn when `FORWARD` does not jump to `DOCKER-USER` (Docker stopped, or using its nftables backend): the container rules would then block nothing.

- `storage-status`: settings file `storage-status.conf` (see `storage-status.conf.example`), overridable by environment variables.
- `storage-status`: configurable free space thresholds (`WARN_PCT`, `CRIT_PCT`), now also applied to pools (`space_status`).
- `storage-status`: last run of every cloud sync task (`cloud_sync`: state, start, end, error).
- `storage-status`: optional Prometheus textfile output (`PROMETHEUS_OUT`), gauges named `storage_status_*`.
- `storage-status`: `generated_epoch`, `thresholds` and `errors` at the top of the JSON. New fields only: `schema_version` stays 1.
- `tests/storage-status-test.py`: storage-status tested in CI against fake `midclt`, `zfs` and `rclone`.

- Documentation: a complete guide in English and Italian (`docs/documentation.md`, `docs/documentazione.md`) with every setting, restoring a backup, common problems and security; HTML pages built with pandoc (`docs/web/build.sh`); the README in Italian (`README.it.md`) and a shorter README.
- `CONTRIBUTING.md`, `SECURITY.md`, issue forms and a pull request template.
- `tests/docs-links-test.py`: checks every relative link and heading anchor of the documentation, in CI.
- `install.sh`: creates or updates the cron jobs and init scripts through the TrueNAS middleware (`--dry-run`, `--disabled`, `--uninstall`); recognises its own jobs, so it can be run again, and reports jobs made by hand that run the same scripts.
- `toolkit.conf`: optional settings shared by heartbeat and system-backup (notifications, Uptime Kuma address); an empty value in a script's own file falls back to it.
- Every script warns, when run by hand, on a TrueNAS version it has not been tested on (tested: 25.10).
- `system-backup/system-backup.sh`: a generic nightly backup driven by `system-backup.conf`: TrueNAS configuration with the secret seed, `app.config` (or every app), PostgreSQL and **MariaDB/MySQL** dumps checked right away, folder archives each with its own apps to stop, checksums, manifest, retention (daily, then monthly, `.keep`), Healthchecks pings and ntfy/webhook notifications. Runs without TrueNAS when the TrueNAS parts are off.
- `system-backup/system-backup-verify.sh`: checks a backup (checksums, configuration database integrity and secret seed, archives read to the end, dump formats); with `--restore`, restores every database into a throwaway container and counts its tables.
- `tests/system-backup-test.sh` (fake `midclt` and `curl`) and `tests/system-backup-restore-test.sh` (real PostgreSQL 16 and MariaDB 11, restored into PostgreSQL 18 and MariaDB 11), both in CI.
- `heartbeat`: generic checks (`CHECKS`): any command, exit code 0 = up, with a time limit (`CHECK_TIMEOUT`) and its own Uptime Kuma push monitor, including the time it took.
- `heartbeat`: notifications to ntfy or to a JSON webhook (`NOTIFY_URL`, `NOTIFY_FORMAT`, `NOTIFY_TOKEN`) when a check goes down or comes back up.
- `heartbeat`: only one run at a time (`flock`): a run still in progress makes the next one skip.
- `tests/heartbeat-test.sh`: heartbeat tested in CI with fake `curl` and `docker`.

### Changed

- `heartbeat`: settings are checked before anything runs; an invalid entry stops it with an error.
- `storage-status`: each section is collected on its own; a failing one no longer stops the script or leaves the JSON file stale: the error is recorded in `errors` and the exit status is 1.
- `lan-guard dry-run` prints the IPv6 rules too, since they can now differ from the IPv4 ones.

## [1.1.0] — 2026-11-19

First feature release after 1.0: a safe way to try lan-guard, and pool health in storage-status.

### Added

- `lan-guard dry-run`: prints the rules `apply` would create, in `iptables-save` syntax, without changing anything and without root.
- `lan-guard`: ports are checked (numbers from 1 to 65535) before the firewall is touched.
- `storage-status`: for every pool, `healthy`, the last scrub or resilver (`scan`: state, errors, progress, age) and every disk with its status and read, write and checksum errors. New fields only: `schema_version` stays 1.
- README: a "Why" section for every script.

## [1.0.0] — 2026-11-19

First public release: every script made generic, documented and tested.

### Added

- `heartbeat.conf` (see `heartbeat.conf.example`): Healthchecks and Tailscale → Uptime Kuma are two independent, optional parts.
- `storage-status`: JSON schema (`docs/storage-status.schema.json`) and an example in the README.
- `storage-status`: pool status, and cloud status `OK`, `LOW`, `CRITICAL` or `ERROR`.
- `storage-status`: tokens refreshed by rclone are saved back to the TrueNAS credential, as TrueNAS does after a cloud sync.
- `lan-guard`: warning when `LAN_IF` does not exist.
- `tests/lan-guard-test.sh`: lan-guard tested against a real firewall in a throwaway container.
- CI on GitHub Actions: shellcheck, ruff, schema check, lan-guard tests.
- MIT license.

### Changed

- `storage-status`: **new output format** (`schema_version` 1): raw values only (bytes, Unix timestamps, hours), grouped in `pools`, `cloud`, `snapshot_space` and `snapshots`; the old `*_display` strings are gone.
- `storage-status`: snapshots are matched with each task's naming schema instead of the `auto-` prefix; several tasks on the same dataset are merged.
- `heartbeat`: no default Uptime Kuma address; the `healthchecks_url` and `kuma_token` files and the `KUMA_URL` variable are replaced by `heartbeat.conf`.
- `lan-guard`: IPv6 is skipped with a warning when `ip6tables` is not available; `iptables -w` everywhere.
- `examples/system-backup.sh`: warning at the top and all site-specific values in one settings block (`APPS_ROOT` instead of a fixed path).
- Comments, messages and output in English.

### Fixed

- `storage-status`: no crash when a pool reports size 0.
- `storage-status`: `generated_at` now has a time zone (ISO 8601).

[2.0.0]: https://github.com/EmaLau/truenas-homelab-toolkit/releases/tag/v2.0.0
[1.1.0]: https://github.com/EmaLau/truenas-homelab-toolkit/releases/tag/v1.1.0
[1.0.0]: https://github.com/EmaLau/truenas-homelab-toolkit/releases/tag/v1.0.0
