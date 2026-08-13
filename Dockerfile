# syntax=docker/dockerfile:1

FROM debian:trixie-slim AS builder

ARG VERSION_ARG="0.0"
ARG MESA_VERSION="25.0.7"
ARG SPICE_VERSION="0.16.0"
ARG DEBIAN_SNAPSHOT="20260809T204446Z"
ARG DEBIAN_FRONTEND="noninteractive"

RUN <<EOF_BUILD_DEPS
  set -eu

  # Bootstrap HTTPS support from the base distribution.
  apt-get update
  apt-get install --no-install-recommends -y ca-certificates

  # Use only the pinned Sid snapshot for all build dependencies.
  rm -f /etc/apt/sources.list.d/debian.sources

  echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ sid main" \
    > /etc/apt/sources.list.d/sid.list

  echo "deb-src [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ sid main" \
    > /etc/apt/sources.list.d/sid-src.list

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
