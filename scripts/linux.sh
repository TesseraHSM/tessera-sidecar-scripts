# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Builds the minimal Linux kernel and initramfs used by the kvm-linux-nosnp variant.
# Intended to be sourced, not executed.
#
# Unlike the Unikraft variants, there is no unikernel here: the application is
# started by the kernel as PID 1 out of an initramfs. It is still the same
# unmodified binary and the same staged root filesystem.

# The kernel this variant is built against. Both values are pinned: the build
# must not silently follow upstream, because a different kernel is a different
# guest. The checksum is the one published in
# https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc
LINUX_VERSION="6.12.112"
LINUX_SHA256="164dc9d1f6c93c61a15e1f071c48379b467f2b17c469cce7223471968208ed03"

# Download and unpack the kernel source, reusing both on a second run.
#
#   linux_fetch_source <cache-dir> <dest-dir>
#
# Prints the path of the extracted source tree.
linux_fetch_source() {
	local cache="$1" dest="$2"
	local tarball="$cache/linux-$LINUX_VERSION.tar.xz"
	local src="$dest/linux-$LINUX_VERSION"

	if [ ! -f "$tarball" ]; then
		log "Downloading linux-$LINUX_VERSION" >&2
		mkdir -p "$cache"
		# Download beside the target and rename only once complete, so that an
		# interrupted run cannot leave a truncated archive that later looks
		# cached.
		curl -fsSL --output "$tarball.part" \
			"https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz" \
			|| die "failed to download linux-$LINUX_VERSION"
		mv "$tarball.part" "$tarball"
	fi

	local actual
	actual="$(sha256sum "$tarball" | cut -d' ' -f1)"
	[ "$actual" = "$LINUX_SHA256" ] \
		|| die "checksum mismatch for $tarball
  expected $LINUX_SHA256
  got      $actual
Delete the file to download it again."

	if [ ! -f "$src/Makefile" ]; then
		log "Extracting linux-$LINUX_VERSION" >&2
		mkdir -p "$dest"
		rm -rf "$src"
		tar -xf "$tarball" -C "$dest"
	fi

	printf '%s\n' "$src"
}

# Turn the staged root filesystem into something the kernel can boot into.
#
#   linux_make_initramfs <linux-src> <rootfs-dir> <out.gz>
#
# Two things are needed beyond what the Unikraft variants use:
#
#   /init         The kernel execs /init as PID 1. A symlink is enough --
#                 execve follows it -- so the binary is not duplicated.
#
#   /dev/console  Without it PID 1 starts with fds 0, 1 and 2 closed: its
#                 output goes nowhere and its first open() lands on fd 0.
#                 Device nodes cannot be created by an unprivileged build, so
#                 the kernel's own gen_init_cpio is used to synthesise a
#                 second, tiny archive that declares one. Linux unpacks
#                 concatenated cpio archives, so appending it is sufficient
#                 and the shared rootfs staging stays untouched.
#
# The result is gzipped. Besides being about a third of the size, this lowers
# the amount of guest memory needed to boot: the kernel decompresses the image
# straight into the tmpfs page cache, so the archive and the unpacked tree never
# have to be resident at the same time the way they do for a raw one.
linux_make_initramfs() {
	local src="$1" rootfs="$2" out="$3"
	local workdir="${out%/*}"
	local raw="$workdir/initramfs.cpio"
	local gen="$workdir/gen_init_cpio"
	local spec="$workdir/devnodes.list"

	ln -sfn "$APP_PACKAGE" "$rootfs/init"

	# Mount points for the application's convenience. The build leaves them
	# empty and nothing mounts them; an initramfs is itself a writable tmpfs,
	# so /tmp needs no mount either.
	mkdir -p "$rootfs/proc" "$rootfs/sys"

	rootfs_make_cpio "$rootfs" "$workdir/rootfs.cpio"

	# A standalone host tool with no kernel headers behind it, so it builds
	# directly rather than through the kernel's build system.
	gcc -O2 -o "$gen" "$src/usr/gen_init_cpio.c" \
		|| die "failed to build gen_init_cpio"

	echo "nod /dev/console 0600 0 0 c 5 1" > "$spec"
	"$gen" "$spec" > "$workdir/devnodes.cpio"

	cat "$workdir/rootfs.cpio" "$workdir/devnodes.cpio" > "$raw"
	gzip -9 -c "$raw" > "$out"
}

# Configure and build the kernel.
#
#   linux_build_kernel <linux-src> <fragment> <jobs>
#
# The configuration starts from tinyconfig rather than defconfig so that what
# ends up in the image is only what the fragment asks for.
#
# The target is vmlinux, not bzImage: the guest is booted through PVH, which
# enters the ELF image directly, so the real-mode setup code and the
# self-decompression stub bzImage wraps around it would never run.
linux_build_kernel() {
	local src="$1" fragment="$2" jobs="$3"

	log "Configuring linux-$LINUX_VERSION"
	make -C "$src" -s tinyconfig
	( cd "$src" && ./scripts/kconfig/merge_config.sh -m .config "$fragment" >/dev/null )
	make -C "$src" -s olddefconfig

	# merge_config.sh is quiet about a symbol it could not set, and olddefconfig
	# will happily drop one whose dependencies are unmet. Either way the result
	# boots into a kernel missing something the application needs, so check
	# that every symbol the fragment asked for actually survived.
	local line symbol value
	while read -r line; do
		case "$line" in
			'# CONFIG_'*' is not set')
				symbol="${line#\# }"
				symbol="${symbol%% is not set}"
				# A symbol whose dependencies are unmet is absent from the
				# resolved configuration rather than listed as unset, so assert
				# what actually matters: that it is not built in or modular.
				! grep -qE "^$symbol=(y|m)\$" "$src/.config" \
					|| die "$symbol is still enabled in the resolved kernel configuration"
				;;
			''|'#'*)
				continue
				;;
			*)
				symbol="${line%%=*}"
				value="${line#*=}"
				grep -qx "$symbol=$value" "$src/.config" \
					|| die "$symbol was not set to '$value' in the resolved kernel configuration"
				;;
		esac
	done < "$fragment"

	log "Building linux-$LINUX_VERSION (-j$jobs)"
	make -C "$src" -j"$jobs" vmlinux
}
