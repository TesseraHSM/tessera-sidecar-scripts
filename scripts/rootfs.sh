# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Builds the initrd that app-elfloader mounts as the unikernel root
# filesystem. Intended to be sourced, not executed.

# Copy a dynamically linked executable together with every shared object it
# needs, so that the ELF loader inside the unikernel can resolve them.
#
#   rootfs_add_binary <rootfs-dir> <binary> <dest-name>
rootfs_add_binary() {
	local rootfs="$1" binary="$2" dest="$3"

	[ -f "$binary" ] || die "application binary not found: $binary"

	install -D -m 0755 "$binary" "$rootfs/$dest"

	# ldd prints one "<soname> => <path> (<addr>)" line per dependency plus a
	# bare "<path> (<addr>)" line for the dynamic loader itself. Keep every
	# absolute path it reports; skip the purely virtual linux-vdso.
	#
	# Capture into a variable rather than piping straight into the loop: ldd
	# exits 0 even when a dependency is "not found", and a process
	# substitution hides its exit status from both set -e and pipefail. Either
	# way the library would be dropped, the build would report success, and
	# the failure would only surface as a loader error at guest boot.
	local ldd_out
	ldd_out="$(ldd "$binary")" \
		|| die "ldd failed on $binary (not a dynamic executable?)"

	if printf '%s\n' "$ldd_out" | grep -q 'not found'; then
		die "unresolved shared libraries for $binary:
$(printf '%s\n' "$ldd_out" | grep 'not found')"
	fi

	# The PT_INTERP recorded in the binary is an absolute path that must exist
	# verbatim, even when the loader itself lives elsewhere on the build host.
	# Determined up front so it can also serve as the "is this dynamically
	# linked?" test below.
	local interp
	interp="$(readelf -l "$binary" 2>/dev/null \
		| sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' \
		| head -n1)"

	# '|| true' keeps a no-match grep from aborting under 'set -e'/pipefail so
	# that an empty result is diagnosed here rather than as a bare exit.
	local libs
	libs="$(printf '%s\n' "$ldd_out" \
		| grep -v 'linux-vdso' \
		| sed -E 's/^.*=> //; s/ \(0x[0-9a-f]+\)$//; s/^[[:space:]]+//' \
		| grep '^/' \
		| sort -u || true)"

	[ -n "$libs" ] || [ -z "$interp" ] \
		|| die "$binary is dynamically linked (PT_INTERP $interp) but no shared library paths were parsed out of ldd:
$ldd_out"

	local lib
	while read -r lib; do
		[ -n "$lib" ] || continue
		[ -e "$lib" ] || die "shared library reported by ldd does not exist: $lib"
		install -D -m 0755 "$lib" "$rootfs${lib}"
	done <<< "$libs"

	if [ -n "$interp" ] && [ ! -e "$rootfs$interp" ]; then
		local host_loader
		host_loader="$(printf '%s\n' "$ldd_out" \
			| sed -n 's#.*\(/[^ ]*ld-linux[^ ]*\).*#\1#p' | head -n1)"
		[ -n "$host_loader" ] || host_loader="$interp"
		[ -e "$host_loader" ] || die "cannot find dynamic loader for $binary"
		install -D -m 0755 "$host_loader" "$rootfs$interp"
	fi
}

# Create the skeleton directories and config files the application expects.
rootfs_add_skeleton() {
	local rootfs="$1"

	mkdir -p "$rootfs/dev" "$rootfs/tmp" "$rootfs/etc/ssl"

	# OpenSSL refuses to initialise if OPENSSL_CONF names a missing file. The
	# application does not read any configuration from it, so an empty file is
	# enough and avoids pulling in the host's distro configuration.
	: > "$rootfs/etc/ssl/openssl.cnf"
}

# Pack the staged tree into a newc cpio archive, which is the format
# vfscore's embedded-initrd automount understands.
rootfs_make_cpio() {
	local rootfs="$1" out="$2"

	( cd "$rootfs" && find . -mindepth 1 -printf '%P\n' | sort \
		| cpio --quiet --create --format=newc --owner=0:0 ) > "$out"
}
