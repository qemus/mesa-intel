# Mesa Intel

Minimal Mesa runtime for Intel GPU acceleration in QEMU, without the full Xorg and LLVM runtime stack.

## Features

- Intel GPU support for QEMU
- Supports the Mesa `i915`, `crocus`, and `iris` Gallium drivers
- EGL and GBM support for headless hardware rendering
- Includes the matching QEMU OpenGL display modules
- LLVM is used during compilation but excluded from the final runtime
- No Xorg server or Intel Xorg DDX driver required
- Produces one self-contained Debian package
- Provides `qemu-system-modules-opengl` and `libgbm1` without installing Debian's LLVM-backed Mesa runtime
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
- QEMU OpenGL display modules matching the configured QEMU version

The package version-provides both:

```text
qemu-system-modules-opengl
libgbm1
```

and conflicts with/replaces their stock Debian packages. This lets other Debian packages satisfy their normal QEMU and GBM dependencies without pulling in `mesa-libgallium` and LLVM.

## Verification

During the build, the package is automatically checked in two stages.

The first stage scans every packaged ELF object with `readelf` and fails if any object directly depends on `libLLVM`.

The finished package is then installed into a clean Debian Trixie image and checked with `ldd`. The build fails if:

- Any runtime dependency cannot be resolved
- LLVM appears anywhere in the runtime dependency tree
- Debian's stock `libgbm1` is installed
- `mesa-libgallium` is installed
- Any `libllvm` runtime package is installed

The full dependency output is printed in the Docker build log.

## Usage

Install the release package together with the matching QEMU packages:

```dockerfile
ARG VERSION_MESA="1.00"

RUN wget \
    "https://github.com/qemus/mesa-intel/releases/download/v${VERSION_MESA}/mesa-intel_${VERSION_MESA}_amd64.deb" \
    -O /tmp/mesa-intel.deb \
 && apt-get update \
 && apt-get --no-install-recommends -y install /tmp/mesa-intel.deb \
 && rm -f /tmp/mesa-intel.deb
```

The package itself carries the QEMU OpenGL module dependency and the Intel Mesa runtime, so consumers do not need to install `xserver-xorg-video-intel`, `qemu-system-modules-opengl`, `libgbm1`, or `mesa-libgallium` separately.

## Intel drivers

The runtime includes Mesa support for multiple generations of Intel integrated graphics:

- `i915` for older Intel GPUs
- `crocus` for older Intel generations supported by the Gallium Crocus driver
- `iris` for newer Intel GPUs

## License

Mesa and QEMU are distributed under their respective upstream licenses. The generated package includes the relevant upstream copyright and license information.
