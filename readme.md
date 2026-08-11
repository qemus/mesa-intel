# Mesa Intel

Minimal Mesa runtime for Intel GPU acceleration in QEMU, without the full Xorg and LLVM runtime stack.

## Features

- Intel GPU support for QEMU
- Supports the Mesa `i915`, `crocus`, and `iris` Gallium drivers
- EGL and GBM support for headless hardware rendering
- LLVM is used during compilation but excluded from the final runtime
- No Xorg server or Intel Xorg DDX driver required
- Produces one self-contained Debian package
- Provides `libgbm1` without installing Debian's LLVM-backed Mesa runtime
- Works independently of the QEMU point release because it contains no QEMU modules
- Verifies compatibility with Debian's official `qemu-system-modules-opengl`
- Verifies that packaged libraries have no direct or transitive LLVM dependencies

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
./dist/mesa-intel_1.00_amd64.deb
```

## Package

The generated `mesa-intel` package contains:

- Mesa `i915`, `crocus`, and `iris` Gallium drivers
- EGL and GBM libraries for headless hardware rendering

The package version-provides:

```text
libgbm1
```

and conflicts with/replaces Debian's stock `libgbm1`. This lets packages such as `qemu-system-modules-opengl` satisfy their normal GBM dependency without pulling in `mesa-libgallium` and LLVM.

The QEMU OpenGL modules themselves are not included. They are installed from Debian alongside the matching QEMU version, so QEMU module build stamps always stay synchronized with the QEMU binaries.

## Verification

During the build, the package is automatically checked in two stages.

The first stage scans every packaged ELF object with `readelf` and fails if any object directly depends on `libLLVM`.

The finished package is then installed into a clean Debian Trixie image together with the official `qemu-system-x86` and `qemu-system-modules-opengl` packages from the configured Debian Sid snapshot. The build fails if:

- Any runtime dependency cannot be resolved
- LLVM appears anywhere in the runtime dependency tree
- Debian's stock `libgbm1` is installed
- `mesa-libgallium` is installed
- Any `libllvm` runtime package is installed

The full dependency output for both `mesa-intel` and the official QEMU OpenGL module is printed in the Docker build log.

## Usage

Install the release package in the same APT transaction as the matching QEMU OpenGL module:

```dockerfile
ARG VERSION_MESA="1.00"
ARG VERSION_QEMU="1:11.0.3+ds-2"

RUN wget \
    "https://github.com/qemus/mesa-intel/releases/download/v${VERSION_MESA}/mesa-intel_${VERSION_MESA}_amd64.deb" \
    -O /tmp/mesa-intel.deb \
 && apt-get update \
 && apt-get --no-install-recommends -y -t sid install \
      /tmp/mesa-intel.deb \
      "qemu-system-modules-opengl=${VERSION_QEMU}" \
 && rm -f /tmp/mesa-intel.deb
```

Because `mesa-intel` provides `libgbm1`, APT can satisfy the QEMU OpenGL module's GBM dependency without installing Debian's stock `libgbm1`, `mesa-libgallium`, or LLVM runtime.

## Intel drivers

The runtime includes Mesa support for multiple generations of Intel integrated graphics:

- `i915` for older Intel GPUs
- `crocus` for older Intel generations supported by the Gallium Crocus driver
- `iris` for newer Intel GPUs

## License

Mesa is distributed under its respective upstream licenses. The generated package includes the relevant upstream copyright and license information.
