# syntax=docker/dockerfile:1

FROM debian:trixie-slim AS builder

ARG MESA_VERSION="25.0.7"
ARG DEBIAN_FRONTEND="noninteractive"

RUN <<'EOF_BUILD_DEPS'
  set -eu

  cat > /etc/apt/sources.list.d/debian-src.list <<'EOF_SOURCES'
deb-src https://deb.debian.org/debian trixie main
deb-src https://deb.debian.org/debian trixie-updates main
deb-src https://security.debian.org/debian-security trixie-security main
EOF_SOURCES

  apt-get update
  apt-get build-dep -y mesa
  apt-get install --no-install-recommends -y \
    binutils \
    ca-certificates \
    curl \
    file \
    gzip \
    meson \
    ninja-build \
    pkg-config \
    xz-utils

  rm -rf /var/lib/apt/lists/*
EOF_BUILD_DEPS

WORKDIR /src

RUN <<EOF_SOURCE
  set -eu

  curl -fL "https://deb.debian.org/debian/pool/main/m/mesa/mesa_${MESA_VERSION}.orig.tar.xz" -o mesa.tar.xz
  mkdir mesa
  tar -xf mesa.tar.xz -C mesa --strip-components=1
  rm -f mesa.tar.xz
EOF_SOURCE

# Build Mesa's shader compiler tools with LLVM available. These tools are used
# only while compiling the final Intel drivers and are never copied to /out.
RUN <<'EOF_TOOLS'
  set -eu

  meson setup /build-tools /src/mesa \
    --buildtype=release \
    -Dbuild-tests=false \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dgallium-drivers=[] \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglx=disabled \
    -Dinstall-mesa-clc=true \
    -Dllvm=enabled \
    -Dmesa-clc=enabled \
    -Dopengl=false \
    -Dplatforms=[] \
    -Dvulkan-drivers=[]

  meson compile -C /build-tools mesa_clc vtn_bindgen

  install -Dm755 /build-tools/src/compiler/clc/mesa_clc /usr/local/bin/mesa_clc
  install -Dm755 /build-tools/src/compiler/spirv/vtn_bindgen /usr/local/bin/vtn_bindgen
EOF_TOOLS

# Build only the Intel Gallium drivers needed for old and new Intel iGPUs.
# LLVM is explicitly disabled in this runtime build; the shader compiler tools
# built above are used only to generate the embedded Iris shader data.
RUN <<'EOF_RUNTIME'
  set -eu

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

  meson setup /build-runtime /src/mesa \
    --buildtype=release \
    --prefix=/usr \
    --libdir="lib/${multiarch}" \
    -Dbuild-tests=false \
    -Degl=enabled \
    -Degl-native-platform=drm \
    -Dgbm=enabled \
    -Dgallium-drivers=i915,crocus,iris \
    -Dgallium-nine=false \
    -Dgallium-opencl=disabled \
    -Dgallium-rusticl=false \
    -Dgallium-va=disabled \
    -Dgallium-vdpau=disabled \
    -Dgallium-xa=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglvnd=disabled \
    -Dglx=disabled \
    -Dintel-elk=true \
    -Dlibunwind=disabled \
    -Dllvm=disabled \
    -Dlmsensors=disabled \
    -Dmesa-clc=system \
    -Dopengl=true \
    -Dplatforms=[] \
    -Dshared-glapi=enabled \
    -Dvalgrind=disabled \
    -Dvideo-codecs=[] \
    -Dvulkan-drivers=[] \
    -Dvulkan-layers=[]

  meson compile -C /build-runtime
  meson install -C /build-runtime --destdir /out

  rm -rf \
    /out/usr/include \
    /out/usr/lib/*/pkgconfig \
    /out/usr/share/doc \
    /out/usr/share/man \
    /out/usr/share/pkgconfig

  find /out -type f -exec sh -c '
    for file do
      if file "$file" | grep -q "ELF"; then
        strip --strip-unneeded "$file"
      fi
    done
  ' sh {} +
EOF_RUNTIME

FROM builder AS verify

# Test 1: every exported ELF object must be free of direct LLVM dependencies.
# Test 2: print the complete dynamic dependency tree for every exported ELF
# object, fail on unresolved libraries, and also reject transitive LLVM loads.
RUN <<'EOF_VERIFY'
  set -eu

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  export LD_LIBRARY_PATH="/out/usr/lib/${multiarch}"

  echo
  echo "Using LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
  echo
  echo "================================================================"
  echo "Test 1: exported ELF objects must not depend directly on LLVM"
  echo "================================================================"

  llvm_direct=0
  for file in $(find /out -type f); do
    file "$file" | grep -q "ELF" || continue

    echo
    echo "--- $file"
    needed="$(readelf -d "$file" 2>/dev/null | grep 'NEEDED' || true)"
    printf '%s\n' "$needed"

    if printf '%s\n' "$needed" | grep -qi 'libLLVM'; then
      echo "FAIL: $file depends directly on LLVM."
      llvm_direct=1
    fi
  done

  if [ "$llvm_direct" -ne 0 ]; then
    echo "FAIL: one or more exported objects directly depend on LLVM."
    exit 1
  fi

  echo "PASS: no direct LLVM dependencies found."

  echo
  echo "================================================================"
  echo "Test 2: ldd runtime dependency scan"
  echo "================================================================"

  missing=0
  llvm_transitive=0

  for file in $(find /out -type f); do
    file "$file" | grep -q "ELF" || continue

    echo
    echo "--- $file"
    deps="$(ldd "$file" 2>&1 || true)"
    printf '%s\n' "$deps"

    if printf '%s\n' "$deps" | grep -q 'not found'; then
      missing=1
    fi

    if printf '%s\n' "$deps" | grep -qi 'libLLVM'; then
      llvm_transitive=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    echo
    echo "FAIL: one or more runtime dependencies could not be resolved."
    exit 1
  fi

  if [ "$llvm_transitive" -ne 0 ]; then
    echo
    echo "FAIL: LLVM appears in the runtime dependency tree."
    exit 1
  fi

  echo
  echo "PASS: all runtime dependencies resolve and LLVM is absent."

  echo
  echo "================================================================"
  echo "Artifact size"
  echo "================================================================"
  du -sh /out
  bytes="$(tar -C /out -cf - . | gzip -9 -c | wc -c)"
  mib="$(awk -v bytes="$bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
  echo "gzip -9 payload: ${bytes} bytes (${mib} MiB)"

  echo
  echo "Exported files:"
  find /out -type f -o -type l | sort
EOF_VERIFY

FROM scratch AS artifact
COPY --from=verify /out/ /
