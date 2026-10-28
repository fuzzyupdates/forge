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
# Tracked-but-deleted worktree entries are skipped (the checkers would die on
# a missing path). *.dockerignore is BuildKit's ignore file, not a Dockerfile.
lst="$(mktemp)"
trap 'rm -f "$lst"' EXIT
git ls-files -z --cached --others --exclude-standard >"$lst"

DOCKERFILES=()
SH_FILES=()
while IFS= read -r -d '' f; do
	[[ -f "$f" ]] || continue
	case "${f##*/}" in
	*.dockerignore) ;;
	Dockerfile | Dockerfile.* | *.Dockerfile | Containerfile | Containerfile.*) DOCKERFILES+=("$f") ;;
	*.sh) SH_FILES+=("$f") ;;
	*)
		if head -n1 -- "$f" 2>/dev/null | grep -qE '^#!(/usr/bin/env[[:space:]]+|/bin/|/usr/bin/)(ba|da|k)?sh([[:space:]]|$)'; then
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
# For every images/<name>/ directory (found via find, so hidden dirs are
# gated locally exactly as CI sees them):
#  * VERSION and Dockerfile must exist;
#  * dir name matches the OCI repository-component rule;
#  * VERSION must be bare semver (publish tags caddy:${VERSION}-builder);
#  * every uncommented CADDY_VERSION= assignment on an ARG line must equal
#    VERSION (any case, any position inside a multi-name ARG); a
#    line-continued ARG declaration fails: the drift loop cannot read it;
#  * at least one FROM consumes ${CADDY_VERSION}, and EVERY caddy base
#    (any case, any registry prefix, any tag form) must ride it — a literal
#    or floating tag is silent drift the version assert cannot catch, since
#    the binary comes from the builder stage;
#  * every xcaddy --with module carries an explicit @v<digit> pin; checks
#    run on line continuations JOINED, so splitting --with across lines
#    cannot hide a floating module. An xcaddy build with zero extractable
#    modules fails outright (extraction evasion is indistinguishable from
#    an intended plugin-less build, and this repo ships plugin builds);
#  * matrix membership both ways: every dir is an exact matrix element and
#    every matrix entry has a dir and a valid name; an empty matrix fails.
PUBLISH=".github/workflows/publish-images.yaml"
NAME_RE='^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$'
mapfile -t IMG_DIRS < <(find images -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
if [[ -d images && ${#IMG_DIRS[@]} -eq 0 ]]; then
	echo "FAIL  images/ exists but contains no image directories"
	fail=1
fi
if ((${#IMG_DIRS[@]})); then
	matrix_ok=0
	if [[ ! -f "$PUBLISH" ]]; then
		echo "FAIL  $PUBLISH missing — no image can publish"
		fail=1
	else
		# exact element list from the (single) inline flow-array matrix line
		matrix_line=$(grep -E '^[[:space:]]*image_name:[[:space:]]*\[' "$PUBLISH" | head -n1 || true)
		if [[ -z "$matrix_line" ]]; then
			echo "FAIL  $PUBLISH: no 'image_name: [...]' matrix line"
			fail=1
		else
			matrix_members=$(sed -E 's/^[^[]*\[(.*)\].*/\1/' <<<"$matrix_line" |
				tr ',' '\n' | sed -E "s/^[[:space:]\"']+//; s/[[:space:]\"']+$//")
			if [[ -z "$(tr -d '[:space:]' <<<"$matrix_members")" ]]; then
				echo "FAIL  $PUBLISH: image_name matrix is empty — nothing would ever publish"
				fail=1
			else
				matrix_ok=1
				while IFS= read -r m; do
					[[ -n "$m" ]] || continue
					if ! [[ "$m" =~ $NAME_RE ]]; then
						echo "FAIL  matrix entry '$m' is not a valid OCI image name"
						fail=1
					elif [[ ! -d "images/$m" ]]; then
						echo "FAIL  matrix entry '$m' has no images/$m directory"
						fail=1
					fi
				done <<<"$matrix_members"
			fi
		fi
	fi
	for dd in "${IMG_DIRS[@]}"; do
		name="$(basename -- "$dd")"
		d="$dd/"
		dir_fail=0
		if ! [[ "$name" =~ $NAME_RE ]]; then
			echo "FAIL  images/$name: dir name must match $NAME_RE (GHCR/CI matrix safety)"
			dir_fail=1
		fi
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
			# comments cannot satisfy a structural check
			nocomment=$(grep -v '^[[:space:]]*#' "${d}Dockerfile")
			# join line continuations so structural checks see logical lines
			joined=$(sed -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /' -e 'ta' <<<"$nocomment")
			if ! grep -qiE '^[[:space:]]*FROM.*[$][{]CADDY_VERSION[}]' <<<"$joined"; then
				echo "FAIL  images/$name: CADDY_VERSION not consumed by a FROM line — the pin is decoration"
				dir_fail=1
			fi
			# EVERY caddy base must ride the pin: any case, any registry
			# prefix, no literal or floating tag
			while IFS= read -r ref; do
				[[ -n "$ref" ]] || continue
				# shellcheck disable=SC2016  # literal ${CADDY_VERSION}, must not expand
				if [[ "${ref,,}" =~ (^|.*/)caddy: ]] && [[ "$ref" != *'${CADDY_VERSION}'* ]]; then
					echo "FAIL  images/$name: FROM base '$ref' is not riding \${CADDY_VERSION} — literal or floating caddy tags are silent drift"
					dir_fail=1
				fi
			done < <(awk 'tolower($1) == "from" {
					for (i = 2; i <= NF; i++) { if ($i !~ /^--/) { print $i; break } }
				}' <<<"$joined")
			if grep -qiE '^[[:space:]]*arg[[:space:]].*\\[[:space:]]*$' <<<"$nocomment"; then
				echo "FAIL  images/$name: line-continued ARG declaration — the drift check cannot read it"
				dir_fail=1
			fi
			# every CADDY_VERSION= assignment must equal VERSION, including
			# positions after the first in a multi-name ARG
			while IFS= read -r assign; do
				av="${assign#*=}"
				av=$(sed -E "s/[\"']//g; s/[[:space:]]*(#.*)?$//" <<<"$av")
				if [[ "$av" != "$v" ]]; then
					echo "FAIL  images/$name: Dockerfile ARG default '$av' != VERSION '$v'"
					dir_fail=1
				fi
			done < <(grep -iE '^[[:space:]]*arg[[:space:]]' <<<"$nocomment" |
				grep -oiE 'CADDY_VERSION=[^[:space:]]+' || true)
			# every xcaddy --with module (on joined lines) must be @v-pinned
			mod_count=0
			while IFS= read -r mod; do
				[[ -n "$mod" ]] || continue
				mod_count=$((mod_count + 1))
				if ! [[ "$mod" =~ @v[0-9] ]]; then
					echo "FAIL  images/$name: xcaddy module '$mod' is unpinned — rebuilds can change bytes"
					dir_fail=1
				fi
			done < <(grep -oE -- '--with[[:space:]]+[^[:space:]]+' <<<"$joined" |
				sed -E 's/^--with[[:space:]]+//' || true)
			if grep -qi xcaddy <<<"$joined" && ((mod_count == 0)); then
				echo "FAIL  images/$name: xcaddy build with zero extractable --with modules (plugin-less or hidden by layout)"
				dir_fail=1
			fi
		fi
		if ((matrix_ok)) && ! grep -qxF -- "$name" <<<"$matrix_members"; then
			echo "FAIL  images/$name not an exact element of the $PUBLISH image_name matrix — it would never publish"
			dir_fail=1
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
