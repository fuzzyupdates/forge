#!/usr/bin/env bash
# forge style gate — see docs/CONTRIBUTING.md.
#
# Usage:
#   ./check.sh          check only; exit non-zero on any violation
#   ./check.sh --fix    auto-fix (shfmt -w), then re-check
#
# Required by every change to this repo (Gate A criterion in CI).
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.local/bin:$PATH"

MODE="check"
if [[ "${1:-}" == "--fix" ]]; then
	MODE="fix"
elif [[ $# -gt 0 ]]; then
	echo "usage: $0 [--fix]" >&2
	exit 2
fi

fail=0

# --- tool availability (fail loudly, never silently skip a check) ---------
need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "ERROR: '$1' not found on PATH (~/.local/bin). See docs/CONTRIBUTING.md for pins." >&2
		exit 3
	}
}
need hadolint
need actionlint
need shfmt
need shellcheck

# --- file discovery (tracked + untracked-not-ignored, via git) ------------
# NUL-delimited: git quotes/escapes non-ASCII filenames by default, so a
# newline-based read can silently omit legal files. Discovery failures must
# abort the gate (materialized; no process substitution swallowing status).
lst="$(mktemp)"
trap 'rm -f "$lst"' EXIT
git ls-files -z --cached --others --exclude-standard >"$lst"

DOCKERFILES=()
SH_FILES=()
while IFS= read -r -d '' f; do
	case "${f##*/}" in
	Dockerfile | Dockerfile.*) DOCKERFILES+=("$f") ;;
	*.sh) SH_FILES+=("$f") ;;
	*)
		if head -n1 -- "$f" 2>/dev/null | grep -qE '^#!.*(bash|sh)'; then
			SH_FILES+=("$f")
		fi
		;;
	esac
done <"$lst"

# --- fix mode -------------------------------------------------------------
if [[ "$MODE" == "fix" ]]; then
	if ((${#SH_FILES[@]})); then
		shfmt -w -- "${SH_FILES[@]}"
	fi
fi

# --- checks ---------------------------------------------------------------
run_check() {
	local label="$1"
	shift
	if "$@"; then
		echo "PASS  $label"
	else
		echo "FAIL  $label"
		fail=1
	fi
}

if ((${#DOCKERFILES[@]})); then
	run_check "hadolint (${#DOCKERFILES[@]} Dockerfiles)" hadolint -- "${DOCKERFILES[@]}"
else
	echo "SKIP  hadolint (no Dockerfiles)"
fi

run_check "actionlint (.github workflows)" actionlint

if ((${#SH_FILES[@]})); then
	# -d (not -l): shfmt -l EXITS 0 while listing unformatted files — vacuous gate.
	run_check "shfmt (${#SH_FILES[@]} bash files)" shfmt -d -- "${SH_FILES[@]}"
	run_check "shellcheck (${#SH_FILES[@]} bash files)" shellcheck -- "${SH_FILES[@]}"
else
	echo "SKIP  shfmt/shellcheck (no bash files)"
fi

# --- image directory invariants --------------------------------------------
# For every images/<name>/ directory:
#  * VERSION and Dockerfile must exist;
#  * VERSION must be bare semver (publish tags caddy:${VERSION}-builder,
#    which has no "v" prefix);
#  * if the Dockerfile declares ARG CADDY_VERSION=<default>, the default must
#    equal VERSION — CI always passes the build arg, so a stale default is
#    silent drift (this repo had exactly that once);
#  * <name> must be listed in the publish workflow's image_name matrix, or a
#    new image silently never publishes.
PUBLISH=".github/workflows/publish-images.yaml"
shopt -s nullglob
IMG_DIRS=(images/*/)
if ((${#IMG_DIRS[@]})); then
	if [[ ! -f "$PUBLISH" ]]; then
		echo "FAIL  $PUBLISH missing — no image can publish"
		fail=1
	fi
	for d in "${IMG_DIRS[@]}"; do
		name="$(basename -- "$d")"
		dir_fail=0
		if [[ ! -f "${d}VERSION" ]]; then
			echo "FAIL  images/$name: missing VERSION"
			dir_fail=1
		fi
		if [[ ! -f "${d}Dockerfile" ]]; then
			echo "FAIL  images/$name: missing Dockerfile"
			dir_fail=1
		fi
		if [[ -f "${d}VERSION" && -f "${d}Dockerfile" ]]; then
			v="$(tr -d '[:space:]' <"${d}VERSION")"
			if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
				echo "FAIL  images/$name/VERSION: '$v' is not bare semver (digits.digits.digits, no leading v)"
				dir_fail=1
			fi
			arg_default="$(sed -n 's/^ARG CADDY_VERSION=\([^ ]*\).*/\1/p' "${d}Dockerfile" | head -n1)"
			if [[ -n "$arg_default" && "$arg_default" != "$v" ]]; then
				echo "FAIL  images/$name: Dockerfile ARG default '$arg_default' != VERSION '$v'"
				dir_fail=1
			fi
		fi
		if [[ -f "$PUBLISH" ]]; then
			if ! grep -Eq 'image_name:[[:space:]]*\[' "$PUBLISH"; then
				echo "FAIL  $PUBLISH: no 'image_name: [...]' matrix line"
				dir_fail=1
			elif ! grep -E 'image_name:[[:space:]]*\[' "$PUBLISH" | grep -qF -- "$name"; then
				echo "FAIL  images/$name not in the $PUBLISH image_name matrix — it would never publish"
				dir_fail=1
			fi
		fi
		if ((dir_fail)); then
			fail=1
		else
			echo "PASS  images/$name invariants"
		fi
	done
fi

if [[ $fail -ne 0 ]]; then
	echo
	echo "Style gate FAILED. Run ./check.sh --fix for auto-fixable issues,"
	echo "then read docs/CONTRIBUTING.md for the rest."
	exit 1
fi
echo "All checks passed."
