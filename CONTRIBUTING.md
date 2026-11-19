# Contributing

Thanks for your interest in the TrueNAS homelab toolkit! Bug reports, ideas and pull requests are all welcome.
Issues and pull requests can be written in **English or Italian**.

## Reporting a bug

Open an [issue](https://github.com/EmaLau/truenas-homelab-toolkit/issues/new/choose) with the **Bug report** form and include:

- the script, the toolkit version (or commit) and your TrueNAS version (`cat /etc/version`);
- what you ran and what happened, with the output or the log;
- your settings file, **with every URL, token and password removed**.

Security problems should not be reported in a public issue: see [SECURITY.md](SECURITY.md).

## Proposing a feature

Use the **Feature request** form: say which problem it solves on your NAS. The scripts stay small and use only what
TrueNAS already has (bash 5, Python 3.11 standard library, `midclt`, `docker`, `iptables`, `rclone`): a feature that
needs extra packages on TrueNAS is unlikely to be accepted.

## Development setup

```bash
git clone https://github.com/EmaLau/truenas-homelab-toolkit.git
cd truenas-homelab-toolkit
python3 tests/storage-status-test.py
bash tests/heartbeat-test.sh
bash tests/system-backup-test.sh
bash tests/install-test.sh
bash tests/system-backup-restore-test.sh      # needs Docker
docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro alpine:3.20 \
  sh -c 'apk add -q iptables ip6tables bash && bash /src/tests/lan-guard-test.sh'
```

The bash tests need GNU tools; on macOS run them in a container, as the comment at the top of each test shows. Lint
with `shellcheck` and `ruff` (without installing them: `uvx --from shellcheck-py shellcheck <files>`, `uvx ruff check .`).
What each test covers is in the [documentation](docs/documentation.md#development).

## Pull requests

- Keep each pull request focused on one change, and add or update tests.
- Run the tests and the linters before opening it: GitHub Actions runs the same checks on every pull request.
- Never put real hostnames, IP addresses, pool names or tokens in code, examples or tests.
- Update the documentation (`README.md`, `docs/documentation.md`) and, when you can, the Italian versions
  (`README.it.md`, `docs/documentazione.md`).
- Add a line to the *Unreleased* section of [CHANGELOG.md](CHANGELOG.md).

By contributing you agree that your contribution is licensed under the [MIT license](LICENSE).
