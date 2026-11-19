# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Changed

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

[Unreleased]: https://github.com/EmaLau/truenas-homelab-toolkit/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/EmaLau/truenas-homelab-toolkit/releases/tag/v1.1.0
[1.0.0]: https://github.com/EmaLau/truenas-homelab-toolkit/releases/tag/v1.0.0
