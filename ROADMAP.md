# Roadmap

Where this project is going. Released versions are described in the [changelog](CHANGELOG.md).

**Status:** 1.0.0 released on 2026-11-19. Every script runs in production on one TrueNAS homelab (TrueNAS 25.10), except the system-backup example, which is a simplified copy of the one running there.

## 1.0 — first public release (done)

Each script made generic, documented and safe to try on someone else's NAS: English everywhere, settings files instead of hard-coded values, a JSON schema for `storage-status`, the system-backup example clearly labelled, CI with shellcheck, ruff and container tests for lan-guard, MIT license.

## Next — features to add after 1.0

In order of priority.

1. **lan-guard**
   - ~~`dry-run` mode that prints the rules without applying them.~~ Done, see the [changelog](CHANGELOG.md).
   - Per-port allowlist of LAN addresses (e.g. let one desktop reach an admin port).
   - Optional logging of dropped connections, rate-limited.
2. **storage-status**
   - ~~Age of the last ZFS scrub and its result for every pool.~~ Done, with pool health and per-disk errors.
   - Optional Prometheus *textfile* output next to the JSON file.
3. **heartbeat**
   - Generic checks: any command whose exit code becomes an up/down push, so one script can watch several services.
4. **system-backup, generic version**: a new script driven by a config file (pools, apps to archive, PostgreSQL containers to dump, retention), keeping the verified-backup ideas of the example: verified `config.save`, `pg_dump` checked with `pg_restore --list`, checksums, manifest, `.incomplete-*` folders.
5. **Installer helpers**: create the post-init script and cron jobs through the TrueNAS middleware instead of by hand.

## Maybe later

- A single `toolkit.conf` shared by all scripts.
- Tests for `storage-status` with recorded `midclt` outputs.

## Not planned

- A dashboard: the scripts produce files and pushes that existing tools (Homepage, Uptime Kuma, Grafana) can read.
