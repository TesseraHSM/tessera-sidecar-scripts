#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Build ddi_sock_server as a Unikraft unikernel, in an SNP or a non-SNP
# variant, or as a minimal Linux guest.
#
# The result is a kernel ELF plus the initrd that was linked into it. Packaging
# that kernel for a particular host is deliberately out of scope for this
# repository.
#
# The 'kvm-linux-nosnp' variant builds the same application and the same root
# filesystem, but runs them on a minimal Linux kernel rather than a unikernel,
# so the initramfs stays a separate file instead of being linked in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh"
# shellcheck source=scripts/rootfs.sh
source "$SCRIPT_DIR/scripts/rootfs.sh"
# shellcheck source=scripts/linux.sh
source "$SCRIPT_DIR/scripts/linux.sh"

APP_PACKAGE="ddi_sock_server"
APP_TARGET="x86_64-unknown-linux-gnu"

# Unikraft declares its constructor tables as `void (*)()`. Under C23, which
# GCC 15 selects by default, that means "takes no arguments" instead of
# "arguments unspecified", so ukboot fails to compile when it passes argc and
# argv to them. Build the kernel as C11 unless the caller says otherwise.
UK_CFLAGS="${UK_CFLAGS:--std=gnu11}"

VARIANT=""
CARGO_PROFILE="release"
JOBS="$(nproc)"
OUT_DIR=""
DO_CLEAN="n"
DO_MENUCONFIG="n"
SKIP_APP="n"

usage() {
	cat <<'EOF'
Usage: build.sh --variant <mshv-unikraft-snp|mshv-unikraft-nosnp|kvm-unikraft-nosnp|kvm-linux-nosnp> [options]

Options:
  --variant <variant>        Which image to build (required):
                               mshv-unikraft-snp    Unikraft, MSHV with AMD SEV-SNP
                               mshv-unikraft-nosnp  Unikraft, MSHV without SEV-SNP
                               kvm-unikraft-nosnp   Unikraft, QEMU/KVM, unencrypted
                               kvm-linux-nosnp      Minimal Linux, QEMU/KVM
  --profile <release|debug>  Cargo profile for the application. Default: release.
  --out <dir>                Where to place the artifacts.
                             Default: build/<variant>/dist.
  --jobs <n>                 Parallel make jobs. Default: nproc.
  --clean                    Remove this variant's build directory first.
  --menuconfig               Open menuconfig after applying the defconfig.
                             Not available for kvm-linux-nosnp.
  --skip-app                 Reuse the existing application binary.
  -h, --help                 Show this help.

Environment overrides:
  UK_ROOT, SW_ROOT, ELFLOADER_ROOT, LIBELF_ROOT
  UK_CFLAGS                  Extra kernel C flags. Default: -std=gnu11.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--variant)       VARIANT="${2:?--variant needs a value}"; shift 2 ;;
		--profile)       CARGO_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
		--out)           OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
		--jobs)          JOBS="${2:?--jobs needs a value}"; shift 2 ;;
		--clean)         DO_CLEAN="y"; shift ;;
		--menuconfig)    DO_MENUCONFIG="y"; shift ;;
		--skip-app)      SKIP_APP="y"; shift ;;
		-h|--help)       usage; exit 0 ;;
		*)               usage >&2; die "unknown argument: $1" ;;
	esac
done

case "$VARIANT" in
	mshv-unikraft-snp|mshv-unikraft-nosnp|kvm-unikraft-nosnp) IS_LINUX="n" ;;
	kvm-linux-nosnp)                                          IS_LINUX="y" ;;
	"") usage >&2; die "--variant is required" ;;
	*)  die "unknown variant '$VARIANT' (expected mshv-unikraft-snp, mshv-unikraft-nosnp, kvm-unikraft-nosnp or kvm-linux-nosnp)" ;;
esac

require_tools git make gcc ld flex bison python3 cpio readelf ldd install cargo

if [ "$IS_LINUX" = "y" ]; then
	[ "$DO_MENUCONFIG" != "y" ] || die "--menuconfig is not supported for kvm-linux-nosnp"
	require_tools curl tar sha256sum gzip strip
	resolve_sw_root
else
	resolve_all_roots
fi

BUILD_DIR="$REPO_ROOT/build/$VARIANT"
ROOTFS_DIR="$BUILD_DIR/rootfs"
INITRD="$BUILD_DIR/initrd.cpio"
KERNEL_BUILD_DIR="$BUILD_DIR/kernel"
DEFCONFIG="$BUILD_DIR/defconfig"
# Keep the resolved .config next to the rest of this variant's output. By
# default Unikraft writes it into the application directory, which would both
# dirty the app-elfloader checkout and make the two variants overwrite each
# other's configuration.
KCONFIG="$BUILD_DIR/.config"
: "${OUT_DIR:=$BUILD_DIR/dist}"

if [ "$DO_CLEAN" = "y" ]; then
	log "Cleaning $BUILD_DIR"
	rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR" "$KERNEL_BUILD_DIR" "$OUT_DIR"

log "Roots"
printf '  sw            %s\n' "$SW_ROOT"
if [ "$IS_LINUX" != "y" ]; then
	printf '  unikraft      %s\n' "$UK_ROOT"
	printf '  app-elfloader %s\n' "$ELFLOADER_ROOT"
	printf '  lib-libelf    %s\n' "$LIBELF_ROOT"
fi

#
# 1. Build the application as an ordinary Linux binary.
#
# It stays a normal dynamically linked glibc executable: app-elfloader runs it
# unmodified, and Unikraft supplies the syscalls underneath.
#
CARGO_ARGS=(build --package "$APP_PACKAGE" --target "$APP_TARGET")
if [ "$CARGO_PROFILE" = "release" ]; then
	CARGO_ARGS+=(--release)
fi
APP_BINARY="$SW_ROOT/target/$APP_TARGET/$CARGO_PROFILE/$APP_PACKAGE"

if [ "$SKIP_APP" = "y" ]; then
	log "Reusing existing application binary"
	[ -f "$APP_BINARY" ] || die "no binary at $APP_BINARY; drop --skip-app"
else
	log "Building $APP_PACKAGE ($CARGO_PROFILE) for $APP_TARGET"
	( cd "$SW_ROOT" && cargo "${CARGO_ARGS[@]}" )
fi

#
# 2. Stage the root filesystem and pack it into an initrd.
#
log "Staging root filesystem"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
rootfs_add_skeleton "$ROOTFS_DIR"
rootfs_add_binary "$ROOTFS_DIR" "$APP_BINARY" "$APP_PACKAGE"

#
# 3. kvm-linux-nosnp: build a Linux kernel and boot the staged tree as an
#     initramfs. There is no unikernel to link, so this is the end of the
#     road for this variant.
#
if [ "$IS_LINUX" = "y" ]; then
	INITRAMFS="$BUILD_DIR/initramfs.cpio.gz"
	LINUX_SRC="$(linux_fetch_source "$REPO_ROOT/.cache" "$BUILD_DIR")"

	log "Creating $INITRAMFS"
	linux_make_initramfs "$LINUX_SRC" "$ROOTFS_DIR" "$INITRAMFS"

	linux_build_kernel "$LINUX_SRC" "$REPO_ROOT/configs/$VARIANT.config" "$JOBS"

	# Stripped: the loader reads program headers and nothing else. The
	# unstripped copy is kept alongside it, mirroring the unikernel variants.
	strip -o "$OUT_DIR/vmlinux" "$LINUX_SRC/vmlinux"
	chmod 0644 "$OUT_DIR/vmlinux"
	install -D -m 0644 "$LINUX_SRC/vmlinux" "$OUT_DIR/vmlinux.dbg"
	install -D -m 0644 "$INITRAMFS" "$OUT_DIR/initramfs.cpio.gz"
	install -D -m 0644 "$LINUX_SRC/.config" "$OUT_DIR/kernel.config"

	log "Done. Artifacts in $OUT_DIR:"
	ls -la "$OUT_DIR"
	exit 0
fi

log "Creating $INITRD"
rootfs_make_cpio "$ROOTFS_DIR" "$INITRD"

#
# 4. Assemble the defconfig.
#
# The initrd path has to be absolute and has to point at the archive that was
# just built, so it is generated here rather than checked in.
#
log "Generating defconfig for variant '$VARIANT'"
{
	cat "$REPO_ROOT/configs/common.config"
	echo
	cat "$REPO_ROOT/configs/$VARIANT.config"
	echo
	echo "# Generated by build.sh"
	echo "CONFIG_LIBVFSCORE_AUTOMOUNT_EINITRD_PATH=\"$INITRD\""
} > "$DEFCONFIG"

#
# 5. Build the unikernel.
#
# app-elfloader is used as the application directory in place, and all build
# output is redirected here so that the submodules stay clean.
#
MAKE_ARGS=(
	-C "$UK_ROOT"
	A="$ELFLOADER_ROOT"
	L="$LIBELF_ROOT"
	O="$KERNEL_BUILD_DIR"
	C="$KCONFIG"
)

log "Applying defconfig"
make "${MAKE_ARGS[@]}" defconfig UK_DEFCONFIG="$DEFCONFIG"

if [ "$DO_MENUCONFIG" = "y" ]; then
	make "${MAKE_ARGS[@]}" menuconfig
fi

log "Building unikernel (-j$JOBS)"
make "${MAKE_ARGS[@]}" -j"$JOBS" UK_CFLAGS="$UK_CFLAGS"

#
# 6. Collect the artifacts.
#
# Unikraft names the image "<UK_NAME>_<plat>-<arch>". Every companion file it
# emits alongside (.dbg, .bootinfo, .multiboot, .cmd) carries a suffix, so
# excluding names containing a dot leaves exactly the bootable image.
#
KERNEL="$(find "$KERNEL_BUILD_DIR" -maxdepth 1 -type f -name '*-x86_64' ! -name '*.*' | head -n1)"
[ -n "$KERNEL" ] || die "could not find a kernel image in $KERNEL_BUILD_DIR"

install -D -m 0644 "$KERNEL" "$OUT_DIR/$(basename "$KERNEL")"
install -D -m 0644 "$INITRD" "$OUT_DIR/initrd.cpio"
install -D -m 0644 "$KCONFIG" "$OUT_DIR/kernel.config"
if [ -f "$KERNEL.dbg" ]; then
	install -D -m 0644 "$KERNEL.dbg" "$OUT_DIR/$(basename "$KERNEL").dbg"
fi

log "Done. Artifacts in $OUT_DIR:"
ls -la "$OUT_DIR"
