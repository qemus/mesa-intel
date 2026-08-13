# syntax=docker/dockerfile:1

FROM debian:trixie-slim AS builder

ARG VERSION_ARG="0.0"
ARG MESA_VERSION="25.0.7"
ARG SPICE_VERSION="0.16.0"
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
    bzip2 \
    curl \
    dpkg-dev \
    file \
    gzip \
    libglib2.0-dev \
    libjpeg-dev \
    libpixman-1-dev \
    libspice-protocol-dev \
    libssl-dev \
    meson \
    ninja-build \
    pkg-config \
    python3-pyparsing \
    python3-six \
    xz-utils \
    zlib1g-dev

  rm -rf /var/lib/apt/lists/*
EOF_BUILD_DEPS

WORKDIR /src

RUN <<EOF_SOURCE
  set -eu

  curl -fL "https://deb.debian.org/debian/pool/main/m/mesa/mesa_${MESA_VERSION}.orig.tar.xz" -o mesa.tar.xz
  mkdir mesa
  tar -xf mesa.tar.xz -C mesa --strip-components=1
  rm -f mesa.tar.xz

  curl -fL "https://deb.debian.org/debian/pool/main/s/spice/spice_${SPICE_VERSION}.orig.tar.bz2" -o spice.tar.bz2
  mkdir spice
  tar -xf spice.tar.bz2 -C spice --strip-components=1
  rm -f spice.tar.bz2
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
RUN <<'EOF_MESA'
  set -eu

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

  meson setup /build-mesa /src/mesa \
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
    -Dglvnd=enabled \
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

  meson compile -C /build-mesa
  meson install -C /build-mesa --destdir /mesa

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
EOF_MESA

# Build a SPICE server runtime for QEMU QXL without the optional multimedia,
# authentication, smartcard and extra compression stacks. QEMU's own SPICE
# modules remain supplied by Debian so their module stamps stay synchronized
# with every QEMU point release.
RUN <<'EOF_SPICE'
  set -eu

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

  meson setup /build-spice /src/spice \
    --buildtype=release \
    --prefix=/usr \
    --libdir="lib/${multiarch}" \
    -Dgstreamer=no \
    -Dlz4=false \
    -Dsasl=false \
    -Dopus=disabled \
    -Dsmartcard=disabled \
    -Dmanual=false \
    -Dstatistics=false \
    -Dinstrumentation=no \
    -Dtests=false

  meson compile -C /build-spice
  meson install -C /build-spice --destdir /spice

  rm -rf \
    /spice/usr/include \
    /spice/usr/lib/*/pkgconfig \
    /spice/usr/share

  # The unversioned linker name belongs to the development package. Keep only
  # the SONAME link and versioned runtime object that libspice-server1 ships.
  rm -f /spice/usr/lib/*/libspice-server.so

  library=$(find /spice/usr/lib -type f -name 'libspice-server.so.1.*' -print -quit)
  if [ -z "$library" ]; then
    echo "FAIL: libspice-server runtime was not produced."
    exit 1
  fi

  if ! readelf -d "$library" | grep -q 'SONAME.*libspice-server.so.1'; then
    echo "FAIL: unexpected SPICE server SONAME."
    readelf -d "$library"
    exit 1
  fi

  find /spice -type f -exec sh -c '
    for file do
      if file "$file" | grep -q "ELF"; then
        strip --strip-unneeded "$file"
      fi
    done
  ' sh {} +
EOF_SPICE

# Package the minimal Mesa and SPICE runtimes together. The package replaces
# only their heavy Debian runtime providers; version-matched QEMU modules are
# deliberately not included.
RUN <<EOF_PACKAGE
  set -eu

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  libdir="/package/usr/lib/${multiarch}"

  mkdir -p /package/DEBIAN
  cp -a /mesa/. /package/
  cp -a /spice/. /package/

  mkdir -p /package/usr/share/doc/qemu-minimal
  cp /src/mesa/docs/license.rst /package/usr/share/doc/qemu-minimal/copyright.Mesa
  cp /src/spice/COPYING /package/usr/share/doc/qemu-minimal/copyright.SPICE

  # Add the Debian packages required by the custom runtimes. Libraries shipped
  # inside this package are intentionally excluded.
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

  printf '%s\n' libegl1 libopengl0 >> /tmp/depends

  sort -u /tmp/depends -o /tmp/depends
  depends="$(paste -sd, /tmp/depends | sed 's/,/, /g')"
  installed_size="$(du -sk /package/usr | cut -f1)"

  cat > /package/DEBIAN/control <<EOF_CONTROL
Package: qemu-minimal
Version: ${VERSION_ARG}
Section: libs
Priority: optional
Architecture: amd64
Maintainer: qemus <qemus@users.noreply.github.com>
Depends: ${depends}
Provides: libgbm1 (= ${MESA_VERSION}), libegl-mesa0 (= ${MESA_VERSION}), libspice-server1 (= ${SPICE_VERSION})
Conflicts: libgbm1, libegl-mesa0, libspice-server1
Replaces: libgbm1, libegl-mesa0, libspice-server1
Installed-Size: ${installed_size}
Homepage: https://github.com/qemus/qemu-minimal
Description: Minimal graphics runtime for QEMU
 Provides an Intel-only Mesa runtime supporting i915, Crocus and Iris together
 with EGL and GBM, plus a minimal SPICE server runtime for QXL, without the
 LLVM, GStreamer, Opus, SASL, smartcard or optional compression runtimes.
EOF_CONTROL

  echo
  echo "================================================================"
  echo "Test 1: packaged ELF dependency isolation"
  echo "================================================================"

  failed=0

  for file in $(find /package/usr -type f); do
    file "$file" | grep -q "ELF" || continue

    echo
    echo "--- $file"
    needed="$(readelf -d "$file" 2>/dev/null | grep 'NEEDED' || true)"
    printf '%s\n' "$needed"

    if printf '%s\n' "$needed" | grep -qi 'libLLVM'; then
      echo "FAIL: $file depends directly on LLVM."
      failed=1
    fi
  done

  spice_library=$(find "$libdir" -type f -name 'libspice-server.so.1.*' -print -quit)
  spice_needed="$(readelf -d "$spice_library" 2>/dev/null | grep 'NEEDED' || true)"

  for unwanted in libgstreamer libgst libopus libsasl liblz4 libcacard liborc; do
    if printf '%s\n' "$spice_needed" | grep -qi "$unwanted"; then
      echo "FAIL: minimal SPICE runtime still depends on $unwanted."
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi

  echo
  echo "PASS: optional Mesa/SPICE dependency stacks are absent."

  mkdir -p /dist
  dpkg-deb \
    --root-owner-group \
    --build \
    /package \
    "/dist/qemu-minimal_${VERSION_ARG}_amd64.deb"

  echo
  echo "================================================================"
  echo "Package metadata"
  echo "================================================================"
  dpkg-deb -I "/dist/qemu-minimal_${VERSION_ARG}_amd64.deb"
  echo
  dpkg-deb -c "/dist/qemu-minimal_${VERSION_ARG}_amd64.deb"
  echo
  du -h "/dist/qemu-minimal_${VERSION_ARG}_amd64.deb"
EOF_PACKAGE

FROM debian:trixie-slim AS verify

ARG VERSION_ARG="0.0"
ARG VERSION_QEMU="1:11.0.3+ds-2"
ARG DEBIAN_SNAPSHOT="20260809T204446Z"
ARG DEBIAN_FRONTEND="noninteractive"

COPY --from=builder /dist/ /dist/

# Install the finished package with Debian's official version-matched QEMU
# OpenGL and SPICE modules. This proves the custom runtime satisfies both
# dependency chains without embedding QEMU modules in qemu-minimal itself.
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
    "/dist/qemu-minimal_${VERSION_ARG}_amd64.deb" \
    "qemu-system-x86=${VERSION_QEMU}" \
    "qemu-system-modules-opengl=${VERSION_QEMU}" \
    "qemu-system-modules-spice=${VERSION_QEMU}"

  echo
  echo "================================================================"
  echo "Package isolation"
  echo "================================================================"

  for package in libgbm1 libegl-mesa0 libspice-server1 mesa-libgallium; do
    if dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -q '^install ok installed$'; then
      echo "FAIL: unwanted stock package was installed: $package"
      exit 1
    fi
  done

  if dpkg-query -W -f='${Status} ${binary:Package}\n' 'libllvm*' 2>/dev/null | grep -q '^install ok installed '; then
    dpkg-query -W -f='${Status} ${binary:Package}\t${Version}\n' 'libllvm*' 2>/dev/null | grep '^install ok installed ' || true
    echo "FAIL: an LLVM runtime package was installed."
    exit 1
  fi

  echo "PASS: stock Mesa/SPICE providers and LLVM are absent."

  echo
  echo "================================================================"
  echo "Runtime loader availability"
  echo "================================================================"

  for library in libEGL.so.1 libOpenGL.so.0 libspice-server.so.1; do
    if ! ldconfig -p | grep -q "$library"; then
      echo "FAIL: required runtime library is missing: $library"
      exit 1
    fi
    echo "PASS: $library is available."
  done

  echo
  echo "================================================================"
  echo "Test 2: installed runtime dependency scan"
  echo "================================================================"

  missing=0
  llvm_transitive=0
  spice_optional=0

  for package in qemu-minimal qemu-system-modules-opengl qemu-system-modules-spice; do
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

      case "$file" in
        *libspice-server.so.1.* )
          if printf '%s\n' "$deps" | grep -Eqi 'lib(gst|gstreamer|opus|sasl|lz4|cacard|orc)'; then
            spice_optional=1
          fi ;;
      esac
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

  if [ "$spice_optional" -ne 0 ]; then
    echo
    echo "FAIL: an optional SPICE dependency reappeared at runtime."
    exit 1
  fi

  echo
  echo "PASS: all runtime dependencies resolve without the removed stacks."

  echo
  echo "================================================================"
  echo "Test 3: QXL module loading"
  echo "================================================================"

  if ! qemu-system-x86_64 -device qxl-vga,help >/tmp/qxl-help 2>&1; then
    cat /tmp/qxl-help
    echo "FAIL: QEMU could not load the QXL device module."
    exit 1
  fi

  cat /tmp/qxl-help
  echo "PASS: QXL device module loaded successfully."

  echo
  echo "================================================================"
  echo "Test 4: QXL with the VNC display path"
  echo "================================================================"

  set +e
  timeout 3s qemu-system-x86_64 \
    -nodefaults \
    -machine pc,accel=tcg \
    -m 64M \
    -monitor none \
    -serial none \
    -vnc unix:/tmp/qxl-vnc.sock \
    -device qxl-vga \
    -S \
    >/tmp/qxl-vnc.log 2>&1
  rc=$?
  set -e

  if [ "$rc" -ne 124 ]; then
    cat /tmp/qxl-vnc.log
    echo "FAIL: QEMU did not remain running with QXL and VNC."
    exit 1
  fi

  echo "PASS: QEMU remained running with QXL and VNC without a SPICE listener."

  echo
  echo "================================================================"
  echo "Installed package status"
  echo "================================================================"
  dpkg-query -W \
    -f='${binary:Package}\t${Version}\n' \
    qemu-minimal \
    qemu-system-x86 \
    qemu-system-common \
    qemu-system-modules-opengl \
    qemu-system-modules-spice \
    libvirglrenderer1 \
    libegl1 \
    libopengl0 \
    libglvnd0
EOF_VERIFY

FROM scratch AS artifact
COPY --from=verify /dist/ /
