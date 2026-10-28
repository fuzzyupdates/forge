# forge

Custom container builds of [Caddy](https://caddyserver.com) with plugins the
official images don't ship. One directory per image under `images/`, built by
GitHub Actions on every push to `main` that touches `images/**` and published
to the GitHub Container Registry.

## Images

- **[`caddy-cloudflare`](images/caddy-cloudflare)** — Caddy plus
  [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare) for DNS-01
  certificate challenges.
  `ghcr.io/fuzzyupdates/forge/caddy-cloudflare:<caddy-version>` and `:latest`

Pin the version tag; `latest` moves whenever any image is republished. For
guaranteed immutability, pin by digest (`@sha256:…`).

```sh
docker pull ghcr.io/fuzzyupdates/forge/caddy-cloudflare:2.11.7
```

## How versions work

- `images/<name>/VERSION` pins the upstream Caddy release. CI passes it to the
  build as `CADDY_VERSION` and the published image is tagged with it.
- When Caddy releases, a bump PR changes `VERSION` (and the Dockerfile `ARG`
  default, which the gate keeps in sync). CI builds the image and verifies the
  built binary reports the pinned version; publishing on `main` re-runs the
  same assertion before pushing to the registry.

## Development

Changes land through pull requests; the owner also pushes `main` directly by
design. Either way CI runs the style gate — locally you can run it first:

```sh
./check.sh        # hadolint, actionlint, shellcheck/shfmt, version invariants
```

Details, tool pins, and the contributing workflow:
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

Apache-2.0 — see [LICENSE](LICENSE). Builds Caddy, which is likewise
Apache-2.0.
