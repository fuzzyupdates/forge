# Contributing

## The style gate

`./check.sh` is the repo gate. CI runs it on every pull request and every push
to `main`; run it before opening a PR. `./check.sh --fix` auto-formats shell
files, then re-check.

Checks, with pinned tool versions:

| Tool | Version | Covers |
| --- | --- | --- |
| hadolint | 2.15.1 | every `Dockerfile` |
| actionlint | 1.7.12 | `.github/workflows/` |
| shellcheck | 0.11.0 | `*.sh` + bash-shebang files |
| shfmt | 3.11.0 | formatting of the same files (gated on `-d`, never `-l`, which exits 0 while listing violations — a vacuous gate) |

Pins live in two places that must change together: the table above, and the
install step in `.github/workflows/check.yml` — which carries the pinned
versions, their sha256 checksums, and post-install `--version` assertions so
neither a replaced release asset nor a stale local binary can impersonate a
pin.

Install locally by downloading the pinned release binaries into
`~/.local/bin` — same URLs and checksums as the CI install step.

## Gate self-test (run after editing check.sh)

The gate must be proven in BOTH directions: a green run on a clean tree proves
nothing until the same run fails on seeded violations.

```sh
./check.sh                                        # must exit 0

# Dockerfile + VERSION + matrix canary (one dir fails three checkers):
mkdir -p images/_gate_canary
printf 'v9.9.9\n' >images/_gate_canary/VERSION    # not bare semver
printf 'FROM scratch\nADD . /\n' >images/_gate_canary/Dockerfile
./check.sh; test $? -eq 1                         # must FAIL
rm -rf images/_gate_canary

# shellcheck canary:
printf '#!/usr/bin/env bash\nread foo\n' >_canary.sh   # SC2162
./check.sh; test $? -eq 1                         # must FAIL
rm _canary.sh

# actionlint canary:
printf 'name: c\non:\n  pull_request:\njobs:\n  x:\n    runs-on: nope\n    steps:\n      - run: echo hi\n' >.github/workflows/_canary.yml
./check.sh; test $? -eq 1                         # must FAIL
rm .github/workflows/_canary.yml

# matrix substring canary (the image name must be an EXACT matrix element;
# 'caddy' is a substring of 'caddy-cloudflare' and must not ride along):
mkdir -p images/caddy
printf '2.11.7\n' >images/caddy/VERSION
printf 'ARG CADDY_VERSION=2.11.7\nFROM caddy:${CADDY_VERSION}-alpine\n' >images/caddy/Dockerfile
./check.sh; test $? -eq 1                         # must FAIL
rm -rf images/caddy

# ARG/VERSION drift canary (Dockerfile default must equal VERSION):
sed -i 's/^ARG CADDY_VERSION=.*/ARG CADDY_VERSION=2.9.9/' images/caddy-cloudflare/Dockerfile
./check.sh; test $? -eq 1                         # must FAIL
git checkout -- images/caddy-cloudflare/Dockerfile

./check.sh                                        # green again
```

## Bumping Caddy

1. Edit `images/<name>/VERSION` to the new bare semver (no leading `v`).
2. If the Dockerfile has an `ARG CADDY_VERSION=` default, keep it identical —
   `check.sh` enforces the sync.
3. Open a PR. CI builds the image and asserts `caddy version` inside it
   reports the pinned value.
4. Merge → `publish-images.yaml` pushes `<version>` and `latest` to GHCR.

## Adding an image

1. `mkdir images/<name>` with a `VERSION` and a `Dockerfile`.
2. Add `<name>` to the `image_name` matrix in
   `.github/workflows/publish-images.yaml` — `check.sh` fails if you forget,
   because the image would then build in PR CI but never publish.
3. Open a PR.
