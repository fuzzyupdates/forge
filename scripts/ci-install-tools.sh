#!/usr/bin/env bash
# Install the pinned style-gate toolchain into ~/.local/bin, checksum-verified
# with exact post-install version field compares. Used by the gate-tools
# composite action (CI + publish) and by contributors locally — same script,
# same pins, and it is itself covered by the gate (shellcheck/shfmt).
# Versions and digests must match the pins table in docs/CONTRIBUTING.md.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

mkdir -p "$HOME/.local/bin"
cd "$HOME/.local/bin"
curl -fsSL --retry 3 -O \
	https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-x86_64
# checksums stored in sha256:<hex> label form (matches how the GitHub assets
# API publishes digests); label stripped for sha256sum -c
echo 'sha256:c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507  hadolint-linux-x86_64' | sed -E 's/^sha256://' | sha256sum -c
mv hadolint-linux-x86_64 hadolint
curl -fsSL --retry 3 -O \
	https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz
echo 'sha256:8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  shellcheck-v0.11.0.linux.x86_64.tar.xz' | sed -E 's/^sha256://' | sha256sum -c
tar -xf shellcheck-v0.11.0.linux.x86_64.tar.xz shellcheck-v0.11.0/shellcheck
mv shellcheck-v0.11.0/shellcheck .
rmdir shellcheck-v0.11.0
curl -fsSL --retry 3 -O \
	https://github.com/mvdan/sh/releases/download/v3.11.0/shfmt_v3.11.0_linux_amd64
echo 'sha256:1904ec6bac715c1d05cd7f6612eec8f67a625c3749cb327e5bfb4127d09035ff  shfmt_v3.11.0_linux_amd64' | sed -E 's/^sha256://' | sha256sum -c
mv shfmt_v3.11.0_linux_amd64 shfmt
curl -fsSL --retry 3 -O \
	https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
echo 'sha256:8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  actionlint_1.7.12_linux_amd64.tar.gz' | sed -E 's/^sha256://' | sha256sum -c
tar -xzf actionlint_1.7.12_linux_amd64.tar.gz actionlint
rm -f shellcheck-v0.11.0.linux.x86_64.tar.xz actionlint_1.7.12_linux_amd64.tar.gz
chmod +x hadolint shellcheck shfmt actionlint

# the binaries must BE the pinned versions — exact field compares, so neither
# a replaced release asset nor a stale PATH copy can impersonate a pin
got=$(./hadolint --version)
[[ "$got" == 'Haskell Dockerfile Linter 2.15.1' ]] || {
	echo "hadolint version '$got'" >&2
	exit 1
}
got=$(./shellcheck --version | awk '/^version:/{print $2}')
[[ "$got" == '0.11.0' ]] || {
	echo "shellcheck version '$got'" >&2
	exit 1
}
got=$(./shfmt --version)
[[ "$got" == 'v3.11.0' ]] || {
	echo "shfmt version '$got'" >&2
	exit 1
}
got=$(./actionlint --version | head -n1)
[[ "$got" == '1.7.12' ]] || {
	echo "actionlint version '$got'" >&2
	exit 1
}
