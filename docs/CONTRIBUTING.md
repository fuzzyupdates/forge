# Contributing

## The style gate

`./check.sh` is the repo gate. CI runs it on every pull request and every push
to `main` (and `publish-images.yaml` runs it again before any publish); run it
before opening a PR. `./check.sh --fix` auto-formats shell files, then re-check.

Checks, with pinned tool versions:

| Tool | Version | Covers |
| --- | --- | --- |
| hadolint | 2.15.1 | every `Dockerfile` |
| actionlint | 1.7.12 | `.github/workflows/` + `.github/actions/` |
| shellcheck | 0.11.0 | `*.sh` + bash-shebang files |
| shfmt | 3.11.0 | formatting of the same files (gated on `-d`, never `-l`, which exits 0 while listing violations — a vacuous gate) |

Pins live in two places that must change together: the table above, and
`.github/actions/gate-tools/action.yml` — which carries the pinned versions,
their sha256 checksums, and exact post-install `--version` field compares, so
neither a replaced release asset nor a stale local binary can impersonate a
pin.

Install locally by downloading the pinned release binaries into
`~/.local/bin` — same URLs and checksums as the composite action.

## Image invariants (`check.sh` enforces, per `images/<name>/`)

- Dir name matches the OCI repository-component rule
  `^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$`.
- `VERSION` is bare semver (publish tags `caddy:${VERSION}-builder`).
- Every uncommented `ARG CADDY_VERSION=` default equals `VERSION`; the
  default must not be line-continued (the drift check can't read it).
- `${CADDY_VERSION}` is consumed by a `FROM` line (comments don't count), and
  no `FROM` pins a `caddy:` base by literal version tag.
- Every xcaddy `--with` module carries an explicit `@v` pin — an unpinned
  module floats, so the same Caddy version could build different bytes.
- `<name>` is an exact element of the publish `image_name` matrix (substring
  matches don't ride), every matrix member has a directory, and an empty
  matrix fails outright.

## Gate self-test (run after editing check.sh)

The gate must be proven in BOTH directions: a green run on a clean tree proves
nothing until the same run fails on seeded violations. Each canary greps for
its own FAIL line — exit 1 from some *other* failure is not a pass. Snapshot
the file you mutate with `cp` and restore from the snapshot: `git checkout --`
silently reverts any unrelated uncommitted edit in that file too (this
happened once and un-pinned the Dockerfile between review rounds).

```sh
./check.sh                                        # must exit 0
cp images/caddy-cloudflare/Dockerfile /tmp/df.snap
cp .github/workflows/publish-images.yaml /tmp/pub.snap

# bare-semver + missing-ARG + substring-ride canary (three checkers at once):
mkdir -p images/_gate_canary
printf 'v9.9.9\n' >images/_gate_canary/VERSION
printf 'FROM scratch\nADD . /\n' >images/_gate_canary/Dockerfile
./check.sh 2>&1 | grep -q 'not bare semver'; test $? -eq 0
rm -rf images/_gate_canary

# shellcheck canary:
printf '#!/usr/bin/env bash\nread foo\n' >_canary.sh   # SC2162
./check.sh 2>&1 | grep -q 'SC2162'; test $? -eq 0
rm _canary.sh

# actionlint canary:
printf 'name: c\non:\n  pull_request:\njobs:\n  x:\n    runs-on: nope\n    steps:\n      - run: echo hi\n' >.github/workflows/_canary.yml
./check.sh >/dev/null 2>&1; test $? -eq 1
rm .github/workflows/_canary.yml

# matrix substring canary ('caddy' is a substring of 'caddy-cloudflare'):
mkdir -p images/caddy
printf '2.11.7\n' >images/caddy/VERSION
printf 'ARG CADDY_VERSION=2.11.7\nFROM caddy:${CADDY_VERSION}-alpine\nRUN true --with pinned@v1.0.0\n' >images/caddy/Dockerfile
./check.sh 2>&1 | grep -q 'not an exact element'; test $? -eq 0
rm -rf images/caddy

# ARG/VERSION drift canary:
sed -i 's/^ARG CADDY_VERSION=.*/ARG CADDY_VERSION=2.9.9/' images/caddy-cloudflare/Dockerfile
./check.sh 2>&1 | grep -q 'ARG default'; test $? -eq 0
cp /tmp/df.snap images/caddy-cloudflare/Dockerfile

# unpinned module canary:
sed -i 's|cloudflare@v0.2.4|cloudflare|' images/caddy-cloudflare/Dockerfile
./check.sh 2>&1 | grep -q 'is unpinned'; test $? -eq 0
cp /tmp/df.snap images/caddy-cloudflare/Dockerfile

# literal caddy tag on FROM canary:
sed -i 's|FROM caddy:${CADDY_VERSION}-alpine|FROM caddy:2.11.7-alpine|' images/caddy-cloudflare/Dockerfile
./check.sh 2>&1 | grep -q 'literal version tag'; test $? -eq 0
cp /tmp/df.snap images/caddy-cloudflare/Dockerfile

# empty-matrix canary:
sed -i 's/image_name: \[caddy-cloudflare\]/image_name: []/' .github/workflows/publish-images.yaml
./check.sh 2>&1 | grep -q 'matrix is empty'; test $? -eq 0
cp /tmp/pub.snap .github/workflows/publish-images.yaml

# phantom matrix entry canary (reverse membership):
sed -i 's/image_name: \[caddy-cloudflare\]/image_name: [caddy-cloudflare, phantom]/' .github/workflows/publish-images.yaml
./check.sh 2>&1 | grep -q "matrix entry 'phantom'"; test $? -eq 0
cp /tmp/pub.snap .github/workflows/publish-images.yaml

./check.sh                                        # green again
```

## Bumping Caddy

1. Edit `images/<name>/VERSION` to the new bare semver (no leading `v`).
2. If the Dockerfile has an `ARG CADDY_VERSION=` default, keep it identical —
   `check.sh` enforces the sync.
3. Bump the `@v` pin on any `--with` module only deliberately, in the same
   PR — plugin changes deserve the same review as the Caddy version.
4. Open a PR. CI builds the image and asserts `caddy version` and
   `caddy list-modules` inside it.
5. Merge → `publish-images.yaml` gates, builds, verifies, then pushes the
   verified artifact as `<version>` and `latest` to GHCR.

## Adding an image

1. `mkdir images/<name>` with a `VERSION` and a `Dockerfile`.
2. Add `<name>` to the `image_name` matrix in
   `.github/workflows/publish-images.yaml` — `check.sh` fails if you forget,
   because the image would then build in PR CI but never publish.
3. Open a PR.

## Trust model (what the guards do NOT claim)

Anyone who can push to `main` can publish: a pushed workflow file runs with
`packages: write` from its own `permissions:` block. The `if: github.ref ==
'refs/heads/main'` guard blocks accidental `workflow_dispatch` against another
branch, not a malicious main-pusher. If that ever matters, the fix is branch
protection + environments (repo settings, owner's call) — not more comments.
