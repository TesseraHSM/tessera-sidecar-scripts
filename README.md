# sidecar-scripts

Builds [`ddi_sock_server`](https://github.com/TesseraHSM/tessera-sw) into a
bootable guest image, either as a [Unikraft](https://unikraft.org) unikernel
running under MSHV or QEMU/KVM, or on a minimal Linux kernel under QEMU/KVM.

## Scope

This repository produces a kernel image and the root filesystem it boots.
Packaging that image for a particular host, and launching it there, is out of
scope, so that the build stays independent of any one host.

The one exception is the QEMU/KVM smoke test in [Running](#running) below. It
needs no packaging step and no tooling beyond `qemu-system-x86_64`, so it is
kept here as the quickest way to prove a build actually works.

## How it works

`ddi_sock_server` is an ordinary Rust program: it uses `tokio` and talks
`AF_VSOCK` through Linux syscalls, and its `tsra_crypto` dependency links
against OpenSSL. Rather than porting it, the unikernel is built from
[`app-elfloader`](https://github.com/unikraft/app-elfloader), which loads and
runs an unmodified Linux ELF binary on top of Unikraft's syscall shim. The
binary, the shared libraries `ldd` reports and its dynamic loader are staged
into a root filesystem that becomes `/`.

The server listens on **vsock port 1234**. The client runs on the host.

The `kvm-linux-nosnp` variant runs the same binary and root filesystem on a
minimal Linux kernel rather than a unikernel. There the root filesystem is an
initramfs rather than an initrd, `/init` is a symlink to the server so the
kernel execs it as PID 1, and its environment comes from the kernel command
line.

## Getting the sources

The Unikraft tree, the application, and two Unikraft libraries
(`app-elfloader` and `lib-libelf`) are git submodules, so clone recursively:

```sh
git clone --recursive <url>
```

For a clone that already exists:

```sh
git submodule update --init --recursive
```

## Host tools

```sh
sudo apt-get install -y build-essential flex bison cpio libncurses-dev libelf-dev git python3
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

`build.sh` preflights `git make gcc ld flex bison python3 cpio readelf ldd
install cargo` and names anything missing. `kvm-linux-nosnp` additionally needs
`curl tar sha256sum gzip strip`.

Any reasonably current GCC works. The kernel is built with `-std=gnu11` by
default, so a GCC that defaults to C23 needs no special handling; override with
`UK_CFLAGS` if you need something else.

## Building

One variant per invocation:

```sh
./build.sh --variant mshv-unikraft-snp
./build.sh --variant mshv-unikraft-nosnp
./build.sh --variant kvm-unikraft-nosnp
./build.sh --variant kvm-linux-nosnp
```

Do not run two builds concurrently: the Unikraft variants share a single source
tree, so they would race on the same configuration and object files. Use
`--jobs` to parallelise within a build instead.

The variants are:

| Variant | Platform | Host | Boot protocol | Isolation |
| --- | --- | --- | --- | --- |
| `mshv-unikraft-snp` | `plat/mshv` | MSHV | lxboot | AMD SEV-SNP |
| `mshv-unikraft-nosnp` | `plat/mshv` | MSHV | lxboot | None |
| `kvm-unikraft-nosnp` | `plat/kvm` | QEMU/KVM | multiboot | None |
| `kvm-linux-nosnp` | Linux 6.12 | QEMU/KVM (`microvm`) | PVH ELF + initramfs | None |

`kvm-linux-nosnp` does not use the Unikraft tree. It builds a kernel from
source, so it takes longer than the other variants: the first run downloads the
kernel tarball (~140 MB) into `.cache/` and checks it against a pinned SHA-256.
The configuration starts from `tinyconfig` and adds only what
`configs/kvm-linux-nosnp.config` asks for.

The kernel is built for QEMU's `microvm` machine, booted through PVH. It has no
PCI and no ACPI, and no bzImage is produced.

Useful options:

| Option | Meaning |
| --- | --- |
| `--profile debug` | Build the application unoptimised |
| `--jobs <n>` | Parallel make jobs. Default: `nproc` |
| `--clean` | Remove the variant's build directory first |
| `--menuconfig` | Inspect or tweak the configuration before building (not for `kvm-linux-nosnp`) |
| `--skip-app` | Reuse the existing application binary |
| `--out <dir>` | Write artifacts somewhere else |

`./build.sh --help` lists these plus the `UK_ROOT` / `SW_ROOT` /
`ELFLOADER_ROOT` / `LIBELF_ROOT` / `UK_CFLAGS` environment overrides.

## Running

Only the `kvm-unikraft-nosnp` and `kvm-linux-nosnp` variants are covered here.

Requires `/dev/kvm`, `/dev/vhost-vsock` and the `vhost_vsock` module.

```sh
sudo apt-get install -y qemu-system-x86
sudo modprobe vhost_vsock
```

### kvm-unikraft-nosnp

```sh
cd build/kvm-unikraft-nosnp/dist
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 256M -nographic -no-reboot \
  -kernel ./ddi_sock_server-kvm-unikraft-nosnp_qemu-x86_64 \
  -append "console=ttyS0 ddi_sock_server" \
  -device vhost-vsock-pci,guest-cid=42
```

Then, in another terminal, from the repository root, using the client built from
`tessera-sw` with `cargo build --release`:

```sh
./tessera/sw/target/release/tsra_ddi_sock_ecc384_loop vsock://42:1234 5
```

Expect five `ECC P-384 n/5 succeeded` lines. `guest-cid` is arbitrary as long as
it is ≥ 3 and matches the client; the port is fixed at 1234 by the server.

Three details are load-bearing:

- **`q35`, not `pc`.** The modern virtio PCI transport needs PCIe config space.
- **`-append` is required.** Multiboot carries argv, and QEMU supplies nothing on
  its own, so omitting it leaves the ELF loader with no program to run. (The
  server itself ignores `argv`, but the loader does not.)
- **`vhost-vsock-pci` gives a real `AF_VSOCK` endpoint**, so the client connects
  directly to the guest CID with no relay in between.

### kvm-linux-nosnp

```sh
cd build/kvm-linux-nosnp/dist
qemu-system-x86_64 -machine microvm,accel=kvm,acpi=off,pit=off,rtc=off \
  -cpu host -m 512M -no-reboot \
  -nodefaults -no-user-config -serial stdio -nographic \
  -kernel ./vmlinux -initrd ./initramfs.cpio.gz \
  -append "console=ttyS0 quiet panic=-1 LD_LIBRARY_PATH=/lib:/usr/lib OPENSSL_CONF=/etc/ssl/openssl.cnf" \
  -device vhost-vsock-device,guest-cid=42
```

The same client then works unchanged. Drop `quiet` to see the kernel log.

The guest needs at least 39 MB.

## License

MIT. See [LICENSE](LICENSE).
