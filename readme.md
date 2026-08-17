# QEMU Minimal

[![Build]][build_url]
[![Version]][release_url]
[![Size]][release_url]

Minimal host graphics runtime for QEMU without the large dependency stacks pulled in by Debian's standard Mesa and SPICE server packages.

## Features

- Intel and AMD GPU support for QEMU
- Supports the Mesa `i915`, `crocus`, `iris`, `r600`, and `radeonsi` Gallium drivers
- EGL and GBM support for headless hardware rendering
- Minimal SPICE server runtime for QEMU QXL
- Keeps Debian's official QEMU OpenGL and SPICE modules
- Works independently of the QEMU point release because it contains no QEMU modules
- LLVM is used during Mesa compilation but excluded from the final runtime
- GStreamer, Opus, SASL, smartcard and optional SPICE compression support are excluded
- No Xorg server or vendor-specific Xorg DDX driver required
- Produces one self-contained Debian package

## Package design

The package version-provides:

```text
libgbm1
libegl-mesa0
libspice-server1
```

and conflicts with/replaces Debian's stock packages with those names. This lets Debian's official QEMU modules satisfy their normal runtime dependencies without pulling the larger stock dependency trees into the final image.

The QEMU modules themselves are deliberately **not** included. Install these from Debian alongside the exact QEMU version:

```text
qemu-system-modules-opengl
qemu-system-modules-spice
```

This keeps QEMU's module build stamps synchronized automatically. Updating QEMU from a point release such as `11.0.3` to `11.0.4` therefore does not require rebuilding `qemu-minimal`.

## Mesa runtime

The Mesa portion contains:

- `i915` for older Intel GPUs
- `crocus` for older Intel generations supported by Gallium Crocus
- `iris` for newer Intel GPUs
- `r600` for older AMD Radeon GPUs based on TeraScale
- `radeonsi` for newer AMD Radeon GPUs based on GCN and RDNA
- EGL and GBM for headless rendering

LLVM is available only while compiling Mesa build-time tools. The final Mesa runtime is built with both `-Dllvm=disabled` and `-Damd-use-llvm=false`, and the finished package is verified to contain no direct or transitive LLVM runtime dependency.

## SPICE runtime

The SPICE portion provides `libspice-server.so.1` for QEMU's QXL implementation while disabling optional features that are unnecessary for the project's VNC/noVNC display path:

- GStreamer video codecs
- Opus audio encoding
- Cyrus SASL authentication
- Smartcard support
- LZ4 compression

The mandatory SPICE server functionality remains built against Pixman, OpenSSL, libjpeg, zlib and GLib.

This package is intended for using QXL through QEMU's normal display path, including QXL together with VNC. It is not intended to provide the full feature set of a conventional remote SPICE deployment.

## Build

Build the Debian package with:

```bash
docker build \
  --progress=plain \
  --target artifact \
  --output type=local,dest=./dist \
  --build-arg VERSION_ARG=1.00 \
  .
```

The resulting package will be written to:

```text
./dist/qemu-minimal_1.00_amd64.deb
```

## Verification

The Docker build verifies the package in a clean Debian Trixie image together with Debian's official, version-matched QEMU OpenGL and SPICE modules.

The build fails if:

- Debian's stock `libgbm1`, `libegl-mesa0`, `libspice-server1`, or `mesa-libgallium` is installed
- LLVM appears anywhere in the runtime dependency tree
- The custom SPICE library links against GStreamer, Opus, SASL, LZ4, libcacard, or Orc
- Any packaged or QEMU module runtime dependency cannot be resolved
- QEMU cannot load `qxl-vga`
- QEMU cannot remain running with QXL and its VNC display backend without a SPICE listener

The full ELF dependency output is printed in the Docker build log.

## Usage

Install `qemu-minimal` before or together with the matching Debian QEMU modules:

```dockerfile
ARG VERSION_MINIMAL="1.0.0"
ARG VERSION_QEMU="1:11.0.3+ds-2"

RUN wget \
    "https://github.com/qemus/qemu-minimal/releases/download/v${VERSION_MINIMAL}/qemu-minimal_${VERSION_MINIMAL}_amd64.deb" \
    -O /tmp/qemu-minimal.deb \
 && apt-get update \
 && apt-get --no-install-recommends -y -t sid install \
      /tmp/qemu-minimal.deb \
      "qemu-system-modules-opengl=${VERSION_QEMU}" \
      "qemu-system-modules-spice=${VERSION_QEMU}" \
 && rm -f /tmp/qemu-minimal.deb
```

Because `qemu-minimal` provides the required Mesa and SPICE runtime package identities, APT can install the official QEMU modules without installing the stock Mesa Gallium/LLVM or full SPICE multimedia dependency chains.

## Stars 🌟
[![Stargazers](https://raw.githubusercontent.com/star-stats/stars/refs/heads/data/charts/qemus-qemu-minimal.svg)](https://github.com/qemus/qemu-minimal/stargazers)

[build_url]: https://github.com/qemus/qemu-minimal/
[release_url]: https://github.com/qemus/qemu-minimal/releases/

[Build]: https://github.com/qemus/qemu-minimal/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/badge/size-18.4_MB-steelblue?style=flat&color=066da5
[Version]: https://img.shields.io/github/v/tag/qemus/qemu-minimal?label=version&sort=semver&color=066da5
