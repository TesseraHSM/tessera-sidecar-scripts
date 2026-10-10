# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Shared helpers for the unikraft-scripts build scripts.
# Intended to be sourced, not executed.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve a dependency root. Order of precedence:
#   1. the environment variable the caller already set
#   2. a submodule/checkout inside this repository
#   3. a sibling checkout next to this repository
#
#   resolve_root <VAR_NAME> <marker> <candidate>...
#
# A candidate only counts if <marker> exists inside it. Testing for the
# directory alone is not enough: a clone without --recursive materialises an
# empty directory for every registered submodule, which would otherwise shadow
# both the sibling fallback and the "git submodule update --init" hint, and
# leave the build to fail later with an unrelated message.
resolve_root() {
	local var_name="$1" marker="$2"; shift 2
	local current="${!var_name:-}"

	if [ -n "$current" ]; then
		[ -d "$current" ] || die "$var_name points at '$current', which does not exist"
		[ -e "$current/$marker" ] \
			|| die "$var_name points at '$current', which does not look like the expected checkout ($marker is missing)"
		(cd "$current" && pwd)
		return 0
	fi

	local candidate
	for candidate in "$@"; do
		if [ -e "$candidate/$marker" ]; then
			(cd "$candidate" && pwd)
			return 0
		fi
	done

	die "could not locate $var_name (tried: $*). Set $var_name explicitly, or run 'git submodule update --init --recursive'"
}

require_tools() {
	local missing=() tool
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		die "missing required tools: ${missing[*]}
Install them, for example:
  sudo apt-get install -y build-essential flex bison cpio libncurses-dev
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
	fi
}

# Populate SW_ROOT, the checkout the application is built from.
#
# Matches on the application this repository actually builds, so a wrong but
# plausible checkout is rejected here rather than by cargo much later.
resolve_sw_root() {
	SW_ROOT="$(resolve_root SW_ROOT examples/sock/ddi_sock_server/Cargo.toml \
		"$REPO_ROOT/tessera/sw" \
		"$REPO_ROOT/../sw")"

	export SW_ROOT
}

# Populate UK_ROOT / SW_ROOT / ELFLOADER_ROOT / LIBELF_ROOT.
resolve_all_roots() {
	resolve_sw_root

	UK_ROOT="$(resolve_root UK_ROOT Config.uk \
		"$REPO_ROOT/tessera/unikraft" \
		"$REPO_ROOT/../unikraft")"

	ELFLOADER_ROOT="$(resolve_root ELFLOADER_ROOT Config.uk \
		"$REPO_ROOT/libs/app-elfloader")"

	LIBELF_ROOT="$(resolve_root LIBELF_ROOT Config.uk \
		"$REPO_ROOT/libs/lib-libelf")"

	export UK_ROOT ELFLOADER_ROOT LIBELF_ROOT
}
