# forge

Custom container builds of [Caddy](https://caddyserver.com) with plugins the
official images don't ship. One directory per image under `images/`, built by
GitHub Actions on every merge to `main` and published to the GitHub Container
Registry.

## Images

- **[`caddy-cloudflare`](images/caddy-cloudflare)** — Caddy plus
  [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare) for DNS-01
  certificate challenges.
  `ghcr.io/fuzzyupdates/forge/caddy-cloudflare:<caddy-version>` and `:latest`

Pin the version tag; `latest` moves whenever any image is republished.

```sh
docker pull ghcr.io/fuzzyupdates/forge/caddy-cloudflare:2.11.7
```

## How versions work

- `images/<name>/VERSION` pins the upstream Caddy release. CI passes it to the
  build as `CADDY_VERSION` and the published image is tagged with it.
- When Caddy releases, a bump PR changes `VERSION` (and the Dockerfile `ARG`
  default, which the gate keeps in sync). CI rebuilds the image and verifies
  the built binary reports the pinned version; publishing happens on merge to
  `main`.

## Development

Every change goes through a pull request and runs the style gate, locally or
in CI:

```sh
./check.sh        # hadolint, actionlint, shellcheck/shfmt, version invariants
```

Details, tool pins, and the contributing workflow:
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

Apache-2.0 — see [LICENSE](LICENSE). Builds Caddy, which is likewise
Apache-2.0.
