# syntax=docker/dockerfile:1

FROM debian:trixie-slim AS builder

ARG VERSION_ARG="0.0"
ARG MESA_VERSION="25.0.7"
ARG DEBIAN_FRONTEND="noninteractive"

RUN <<'EOF_BUILD_DEPS'
  set -eu

  apt-get update
  apt-get install --no-install-recommends -y ca-certificates

  cat > /etc/apt/sources.list.d/debian-src.list <<'EOF_SOURCES'
deb-src https://deb.debian.org/debian trixie main
deb-src https://deb.debian.org/debian trixie-updates main
deb-src https://security.debian.org/debian-security trixie-security main
EOF_SOURCES

  apt-get update
  apt-get build-dep -y mesa
  apt-get install --no-install-recommends -y \
    binutils \
    curl \
    dpkg-dev \
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
# only while compiling the final Intel drivers and are never packaged.
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
  meson install -C /build-runtime --destdir /mesa

  rm -rf \
    /mesa/usr/include \
    /mesa/usr/lib/*/pkgconfig \
    /mesa/usr/share/doc \
    /mesa/usr/share/man \
    /mesa/usr/share/pkgconfig

  find /mesa -type f -exec sh -c '
    for file do
      if file "$file" | grep -q "ELF"; then
        strip --strip-unneeded "$file"
      fi
    done
  ' sh {} +
EOF_RUNTIME

# Package the Intel-only Mesa runtime as a replacement provider for libgbm1.
# This lets Debian packages use the custom GBM implementation without pulling
# the stock mesa-libgallium and LLVM runtime into the final image.
RUN <<EOF_PACKAGE
  set -eu

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  libdir="/package/usr/lib/${multiarch}"

  mkdir -p /package/DEBIAN
  cp -a /mesa/. /package/

  mkdir -p /package/usr/share/doc/mesa-intel
  cp /src/mesa/docs/license.rst /package/usr/share/doc/mesa-intel/copyright.Mesa

  # Add the Debian packages required by the custom Mesa runtime. Libraries
  # shipped inside this package are intentionally excluded.
  : > /tmp/depends

  find /package/usr -type f -exec sh -c '
    libdir=$1
    shift

    for file do
      file "$file" | grep -q "ELF" || continue

      LD_LIBRARY_PATH="$libdir" ldd "$file" 2>/dev/null \
        | awk "
            /=> \// { print \$3 }
            /^[[:space:]]*\/[^ ]/ { print \$1 }
          "
    done
  ' sh "$libdir" {} + \
    | sort -u \
    | while IFS= read -r library; do
        [ -n "$library" ] || continue

        case "$library" in
          /package/*) continue ;;
        esac

        library="$(realpath "$library")"
        owner="$(dpkg-query -S "$library" 2>/dev/null | head -n 1 || true)"
        [ -n "$owner" ] || continue

        owner="${owner%%:*}"
        echo "$owner" >> /tmp/depends
      done

  sort -u /tmp/depends -o /tmp/depends
  depends="$(paste -sd, /tmp/depends | sed 's/,/, /g')"
  installed_size="$(du -sk /package/usr | cut -f1)"

  cat > /package/DEBIAN/control <<EOF_CONTROL
Package: mesa-intel
Version: ${VERSION_ARG}
Section: libs
Priority: optional
Architecture: amd64
Maintainer: qemus <qemus@users.noreply.github.com>
Depends: ${depends}
Provides: libgbm1 (= ${MESA_VERSION})
Conflicts: libgbm1
Replaces: libgbm1
Installed-Size: ${installed_size}
Homepage: https://github.com/qemus/mesa-intel
Description: Minimal Intel Mesa runtime for QEMU
 Provides an Intel-only Mesa runtime supporting i915, Crocus and Iris together
 with EGL and GBM, without an LLVM runtime dependency.
EOF_CONTROL

  echo
  echo "================================================================"
  echo "Test 1: packaged ELF objects must not depend directly on LLVM"
  echo "================================================================"

  llvm_direct=0

  for file in $(find /package/usr -type f); do
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
    echo "FAIL: one or more packaged objects directly depend on LLVM."
    exit 1
  fi

  echo
  echo "PASS: no direct LLVM dependencies found."

  mkdir -p /dist
  dpkg-deb \
    --root-owner-group \
    --build \
    /package \
    "/dist/mesa-intel_${VERSION_ARG}_amd64.deb"

  echo
  echo "================================================================"
  echo "Package metadata"
  echo "================================================================"
  dpkg-deb -I "/dist/mesa-intel_${VERSION_ARG}_amd64.deb"
  echo
  dpkg-deb -c "/dist/mesa-intel_${VERSION_ARG}_amd64.deb"
  echo
  du -h "/dist/mesa-intel_${VERSION_ARG}_amd64.deb"
EOF_PACKAGE

FROM debian:trixie-slim AS verify

ARG VERSION_ARG="0.0"
ARG VERSION_QEMU="1:11.0.3+ds-2"
ARG DEBIAN_SNAPSHOT="20260809T204446Z"
ARG DEBIAN_FRONTEND="noninteractive"

COPY --from=builder /dist/ /dist/

# Install the finished package together with the official matching QEMU OpenGL
# module in a clean Trixie image. This verifies that mesa-intel satisfies the
# libgbm1 dependency without pulling Debian's LLVM-backed Mesa runtime back in.
RUN <<EOF_VERIFY
  set -eu

  apt-get update
  apt-get install --no-install-recommends -y \
    binutils \
    ca-certificates \
    file

  echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ sid main" \
    > /etc/apt/sources.list.d/qemu-snapshot.list

  apt-get update
  apt-get --no-install-recommends -y -t sid install \
    "/dist/mesa-intel_${VERSION_ARG}_amd64.deb" \
    "qemu-system-x86=${VERSION_QEMU}" \
    "qemu-system-modules-opengl=${VERSION_QEMU}"

  echo
  echo "================================================================"
  echo "Package isolation"
  echo "================================================================"

  for package in libgbm1 mesa-libgallium; do
    if dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -q '^install ok installed$'; then
      echo "FAIL: unwanted package was installed: $package"
      exit 1
    fi
  done

  if dpkg-query -W -f='${Status} ${binary:Package}\n' 'libllvm*' 2>/dev/null | grep -q '^install ok installed '; then
    dpkg-query -W -f='${Status} ${binary:Package}\t${Version}\n' 'libllvm*' 2>/dev/null | grep '^install ok installed ' || true
    echo "FAIL: an LLVM runtime package was installed."
    exit 1
  fi

  echo "PASS: stock libgbm1, mesa-libgallium and LLVM are absent."

  echo
  echo "================================================================"
  echo "Test 2: installed runtime dependency scan"
  echo "================================================================"

  missing=0
  llvm_transitive=0

  for package in mesa-intel qemu-system-modules-opengl; do
    for file in $(dpkg-query -L "$package"); do
      [ -f "$file" ] || continue
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
  echo "Installed package status"
  echo "================================================================"
  dpkg-query -W \
    -f='${binary:Package}\t${Version}\n' \
    mesa-intel \
    qemu-system-x86 \
    qemu-system-common \
    qemu-system-modules-opengl \
    libvirglrenderer1
EOF_VERIFY

FROM scratch AS artifact
COPY --from=verify /dist/ /
