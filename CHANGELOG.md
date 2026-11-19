# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/EmaLau/truenas-homelab-toolkit/releases/tag/v1.0.0
