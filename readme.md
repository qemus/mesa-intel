# Mesa Intel

Minimal Mesa runtime for Intel GPU acceleration in QEMU, without the full Xorg and LLVM runtime stack.

## Features

- Intel GPU support for QEMU
- Supports the Mesa `i915`, `crocus`, and `iris` Gallium drivers
- EGL and GBM support for headless hardware rendering
- LLVM is used during compilation but excluded from the final runtime
- No Xorg server or Intel Xorg DDX driver required
- Produces a small runtime artifact suitable for copying into other container images
- Verifies that exported libraries have no direct or transitive LLVM dependencies

## Build

Build the runtime artifact with:

```bash
docker build \
  --progress=plain \
  --target artifact \
  --output type=local,dest=./dist \
  .
```

The resulting Mesa runtime will be written to:

```text
./dist
```

## Verification

During the build, the runtime is automatically checked using both `readelf` and `ldd`.

The build will fail if:

- Any exported ELF object directly depends on `libLLVM`
- LLVM appears anywhere in the runtime dependency tree
- Any required shared library cannot be resolved

The build log also reports the final uncompressed and gzip-compressed artifact size.

## Usage

The generated runtime is intended to be copied into a QEMU container image instead of installing the full Mesa/Xorg graphics stack.

For example:

```dockerfile
COPY --from=mesa-intel /usr/ /usr/
```

The QEMU image still needs the matching QEMU OpenGL module, such as `qemu-system-modules-opengl`.

## Intel drivers

The runtime includes Mesa support for multiple generations of Intel integrated graphics:

- `i915` for older Intel GPUs
- `crocus` for older Intel generations supported by the Gallium Crocus driver
- `iris` for newer Intel GPUs

## License

Mesa is distributed under its respective upstream licenses. See the Mesa source distribution for details.
