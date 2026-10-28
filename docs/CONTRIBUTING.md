# Contributing

## The style gate

`./check.sh` is the repo gate. CI runs it on every pull request and every push
to `main` (and `publish-images.yaml` runs it again before any publish); run it
before opening a PR. `./check.sh --fix` auto-formats shell files, then re-check.

Checks, with pinned tool versions:

| Tool | Version | Covers |
| --- | --- | --- |
| hadolint | 2.15.1 | every `Dockerfile` |
| actionlint | 1.7.12 | `.github/workflows/` + `.github/actions/` YAML (it does not shellcheck composite `run:` bodies — the gate-tools installer therefore lives in `scripts/ci-install-tools.sh`, which the gate itself checks) |
| shellcheck | 0.11.0 | `*.sh` + bash-shebang files (incl. the installer) |
| shfmt | 3.11.0 | formatting of the same files (gated on `-d`, never `-l`, which exits 0 while listing violations — a vacuous gate) |

Pins live in two places that must change together: the table above, and
`scripts/ci-install-tools.sh` — which carries the pinned versions, their
sha256 checksums, and exact post-install `--version` field compares, so a
replaced release asset cannot impersonate a pin. Note the limit: CI asserts
the versions it installs; a **local** `check.sh` only proves a tool is on
PATH, so keep your local binaries updated to the table.

Install locally with the same script CI runs: `bash scripts/ci-install-tools.sh`.

## Image invariants (`check.sh` enforces, per `images/<name>/`)

Checks run on **line continuations joined**, so reformatting cannot hide a
violation.

- Dir name matches the OCI repository-component rule
  `^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$` (hidden dirs are found too — local
  and CI enumerate identically).
- `VERSION` is bare semver (publish tags `caddy:${VERSION}-builder`).
- Every uncommented `CADDY_VERSION=` assignment on an `ARG` line equals
  `VERSION`, at any position in a multi-name `ARG`; a line-continued `ARG`
  declaration fails outright (the drift loop cannot read it).
- At least one `FROM` consumes `${CADDY_VERSION}`, and **every** `caddy:`
  base — any case, any registry prefix — rides it. A literal or floating tag
  is silent drift the built-binary version assert cannot catch, because the
  binary comes from the builder stage.
- Every xcaddy `--with` module carries an explicit `@v<digit>` pin. An xcaddy
  build with zero extractable `--with` modules fails: extraction evasion is
  indistinguishable from an intended plugin-less build, and this repo ships
  plugin builds.
- Matrix membership both ways: every dir is an exact element of the publish
  `image_name` matrix (substring matches don't ride), every matrix entry is
  name-valid and has a directory, and an empty matrix fails outright.

## Gate self-test (run after editing check.sh)

The gate must be proven in BOTH directions, and each canary must grep for
**its own FAIL line** — exit 1 from some *other* failure is not a pass.
Snapshot files you mutate with `cp` and restore from the snapshot:
`git checkout --` silently reverts any unrelated uncommitted edit in that
file too (that is how the Dockerfile pin once vanished between review
rounds). Canary mutations must also vary **layout** (case, registry prefix,
line continuation, multi-name `ARG`), not just values — the corpus that
proved every rule green still leaked a continuation-split `--with`.

```sh
# This block is a script: run it with `set -euo pipefail` and it exits 0 only
# if every canary fails with ITS OWN FAIL line and the final gate is green.
set -euo pipefail
DF=images/caddy-cloudflare/Dockerfile
PUB=.github/workflows/publish-images.yaml
cp "$DF" /tmp/df.snap; cp "$PUB" /tmp/pub.snap

must_fail() { # $1 = FAIL substring the gate must print
  local out rc=0
  ./check.sh >/tmp/check.out 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || { echo "EXPECTED FAIL ('$1') but gate exited 0"; return 1; }
  grep -qF -- "$1" /tmp/check.out || { echo "FAIL line missing: '$1'"; cat /tmp/check.out; return 1; }
}
must_pass() { ./check.sh; }
restore() { cp /tmp/df.snap "$DF"; cp /tmp/pub.snap "$PUB"; }

must_pass   # clean tree

mkdir -p images/_gate_canary
printf 'v9.9.9\n' >images/_gate_canary/VERSION
printf 'FROM scratch\nADD . /\n' >images/_gate_canary/Dockerfile
must_fail 'not bare semver'; must_fail 'not consumed by a FROM'
rm -rf images/_gate_canary

printf '#!/usr/bin/env bash\nread foo\n' >_canary.sh
must_fail 'SC2162'; rm _canary.sh

printf 'name: c\non:\n  pull_request:\njobs:\n  x:\n    runs-on: nope\n    steps:\n      - run: echo hi\n' >.github/workflows/_canary.yml
must_fail 'nope'; rm .github/workflows/_canary.yml

mkdir -p images/caddy   # 'caddy' is a substring of 'caddy-cloudflare'
printf '2.11.7\n' >images/caddy/VERSION
printf 'ARG CADDY_VERSION=2.11.7\nFROM caddy:${CADDY_VERSION}-alpine\nRUN true --with pinned@v1.0.0\n' >images/caddy/Dockerfile
must_fail 'not an exact element'; rm -rf images/caddy

sed -i 's/^ARG CADDY_VERSION=.*/ARG CADDY_VERSION=2.9.9/' "$DF"
must_fail 'ARG default'; restore

sed -i 's/^ARG CADDY_VERSION=.*/ARG BUILD_DATE=x CADDY_VERSION=2.9.9/' "$DF"
must_fail 'ARG default'; restore

sed -i 's|cloudflare@v0.2.4|cloudflare|' "$DF"
must_fail 'unpinned or replaced'; restore

# continuation-split --with (the layout attack):
python3 -c 'import pathlib; p=pathlib.Path("'"$DF"'"); s=p.read_text();
p.write_text(s.replace("    --with github.com/caddy-dns/cloudflare@v0.2.4 \\\n",
"    --with \\\n    github.com/caddy-dns/cloudflare \\\n"))'
must_fail 'unpinned or replaced'; restore

# blank line inside a continuation (Docker accepts it, naive joins do not):
python3 -c 'import pathlib; p=pathlib.Path("'"$DF"'"); s=p.read_text();
p.write_text(s.replace("    --with github.com/caddy-dns/cloudflare@v0.2.4 \\\n",
"    --with github.com/caddy-dns/cloudflare@v0.2.4 \\\n    --with \\\n\n    github.com/evil/mod \\\n"))'
must_fail 'unpinned or replaced'; restore

sed -i 's|cloudflare@v0.2.4|cloudflare@v0.2.4=github.com/evil/mod|' "$DF"
must_fail 'unpinned or replaced'; restore

sed -i 's|caddy:${CADDY_VERSION}-alpine|caddy:alpine|' "$DF"
must_fail 'not riding'; restore

sed -i 's|FROM caddy:${CADDY_VERSION}-builder|from caddy:${CADDY_VERSION}-builder|' "$DF"
must_pass; restore   # lowercase, still riding: legal
sed -i 's|FROM caddy:${CADDY_VERSION}-builder|from caddy:2.11.7-builder|' "$DF"
must_fail 'not riding'; restore

sed -i 's|FROM caddy:${CADDY_VERSION}-builder|FROM docker.io/library/caddy:2.11.7-builder|' "$DF"
must_fail 'not riding'; restore

sed -i 's|caddy:${CADDY_VERSION}-alpine|caddy@sha256:aaaa|' "$DF"
must_fail 'not riding'; restore

sed -i 's|FROM caddy:${CADDY_VERSION}-alpine|ARG BASE=whatever\nFROM ${BASE}|' "$DF"
must_fail 'bare variable'; restore

sed -i 's/image_name: \[caddy-cloudflare\]/image_name: []/' "$PUB"
must_fail 'matrix is empty'; restore

sed -i 's/image_name: \[caddy-cloudflare\]/image_name: [caddy-cloudflare, phantom]/' "$PUB"
must_fail "matrix entry 'phantom'"; restore

sed -i 's/image_name: \[caddy-cloudflare\]/image_name: [caddy-cloudflare, .]/' "$PUB"
must_fail 'not a valid OCI image name'; restore

mkdir -p images/.hidden   # local enumeration must match CI's find
printf '2.11.7\n' >images/.hidden/VERSION
printf 'ARG CADDY_VERSION=2.11.7\nFROM caddy:${CADDY_VERSION}-alpine\nRUN true --with pinned@v1.0.0\n' >images/.hidden/Dockerfile
must_fail 'dir name must match'; rm -rf images/.hidden

python3 -c 'import pathlib; p=pathlib.Path("'"$DF"'"); s=p.read_text();
p.write_text(s.replace("    --with github.com/caddy-dns/cloudflare@v0.2.4 \\\n", ""))'
must_fail 'zero extractable'; restore

must_pass   # green again
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
   verified artifact (version tag first, then `latest`) to GHCR.

## Adding an image

1. `mkdir images/<name>` with a `VERSION` and a `Dockerfile`.
2. Add `<name>` to the `image_name` matrix in
   `.github/workflows/publish-images.yaml` — `check.sh` fails if you forget,
   because the image would then build in PR CI but never publish.
3. Open a PR.

## Trust model (what the guards do NOT claim)

Anyone who can push a branch can potentially publish: a pushed workflow file
runs with the permissions its own `permissions:` block asks for, so the
`if: github.ref == 'refs/heads/main'` guard stops accidental
`workflow_dispatch` against another branch — not a malicious pusher.
Environment protection does not close this either: it only applies to jobs
that declare `environment:`, and a pushed workflow simply omits it. The real
fix, if it ever matters, is at the registry/credential layer — remove the
repo's Actions write role on the GHCR package and publish with an
environment-scoped credential (GitHub App or fine-grained PAT) restricted to
the `main` deployment branch. Owner's call; today the repo is a single-owner
homelab tool.
