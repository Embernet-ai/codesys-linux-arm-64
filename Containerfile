# syntax=docker/dockerfile:1.7
#
# Embernet CODESYS Control for Linux ARM64 SL — Debian wrapper.
#
# Wraps the upstream CODESYS Control SL .deb (extracted from CODESYS GmbH's
# .package distribution) in a debian:bookworm-slim base so it installs
# cleanly on any Linux host regardless of distro — particularly openSUSE
# MicroOS (RPM-based) where dpkg-installing a .deb directly is not viable.
#
# CODESYS GmbH explicitly supports running this runtime in a container:
# the .deb's postinst script branches on $CONTAINER / /.dockerenv /
# /run/.containerenv and skips the host-side daemon registration when it
# detects a container environment. We set CONTAINER=true so the postinst
# does the right thing, then we manage the daemon lifecycle ourselves via
# the Quadlet [Service] section on the Pi appliance.
#
# Built with:
#   podman build --platform linux/arm64 \
#     --manifest ghcr.io/embernet-ai/codesys-linux-arm-64:latest \
#     --build-arg CODESYS_VERSION=4.20.0.0 \
#     -f Containerfile .
#
# CI publishes :latest and the version tag on every push to main; see
# .github/workflows/build.yml.

ARG CODESYS_VERSION=4.20.0.0

FROM debian:bookworm-slim

ARG CODESYS_VERSION

LABEL org.opencontainers.image.title="Embernet CODESYS Control for Linux ARM64 SL"
LABEL org.opencontainers.image.description="CODESYS Control runtime (PLC IEC 61131-3, ARM64) wrapped in debian:bookworm-slim for distro-agnostic deployment via Quadlet on EmberNet edge appliances"
LABEL org.opencontainers.image.vendor="Fireball Industries"
LABEL org.opencontainers.image.source="https://github.com/Embernet-ai/codesys-linux-arm-64"
LABEL codesys.version="${CODESYS_VERSION}"

# Tell the .deb's postinst we're a container so it skips host-daemon
# registration. Quadlet handles daemon lifecycle on the Pi.
ENV CONTAINER=true

# Install unzip + ca-certs (needed to fetch and unpack the .package). We
# install via --force-depends because the .deb's `Depends: codemeter |
# codemeter-lite` line points at WIBU SystemSec's proprietary license
# daemon, which is not in Debian's main repos. CODESYS Control SL runs in
# 30-minute demo cycles without CodeMeter — perfect for unlicensed bring-up.
# To enable real licensing later: add WIBU's apt repo, install
# codemeter-lite, then drop --force-depends and rebuild.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      unzip ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Pull the CODESYS Package (a ZIP wrapping the .deb + IDE-side helper files)
# from our public release at Embernet-ai/codesys-linux-arm-64.
ADD https://github.com/Embernet-ai/codesys-linux-arm-64/releases/download/v${CODESYS_VERSION}/CODESYS.Control.for.Linux.ARM64.SL.${CODESYS_VERSION}.package /tmp/codesys.package

# Unzip the .package, then dpkg-install ONLY the .deb. The other contents
# (Devices/, Help/, Html/, Libraries/) are CODESYS IDE-side bait — only the
# Windows-side CODESYS Installer GUI uses them. We don't.
#
# Hard post-install assertions follow the dpkg call. dpkg --force-depends
# masks the codemeter dep but does NOT mask other postinst failures.
# If postinst aborted before registering CmpRetain in the user component
# list, CmpApp safe-modes at runtime on the RetainUpdate import (this
# is the failure mode that took universaltester004's cp02 down for 9
# days — see Embernet-ai/Codesys-AMD-64-x86 PR #1). Fail the IMAGE
# BUILD here instead of producing a "looks fine" image that safe-modes
# in prod. Paths verified by extracting the actual .deb (postinst +
# /etc/init.d/codesyscontrol:17,20,65).
RUN unzip /tmp/codesys.package -d /tmp/codesys \
 && dpkg -i --force-depends \
      /tmp/codesys/Delivery/linuxarm64/codesyscontrol_linuxarm64_${CODESYS_VERSION}_arm64.deb \
 && test -x /opt/codesys/bin/codesyscontrol.bin \
 && test -f /etc/codesyscontrol/CODESYSControl.cfg \
 && test -f /etc/codesyscontrol/CODESYSControl_User.cfg \
 && grep -q '^Component\..*=CmpRetain' /etc/codesyscontrol/CODESYSControl_User.cfg \
 && rm -rf /tmp/codesys.package /tmp/codesys \
 && rm -rf /var/lib/apt/lists/*

# Ports the runtime exposes. Bound on 0.0.0.0 inside the container; on the
# Pi the Quadlet uses --network host so these become reachable on the host's
# WG mesh IP and LAN IP.
EXPOSE 1217/tcp 4840/tcp 8080/tcp 11740/tcp

# codesyscontrol.bin runs PID 1 directly. Path + cfg taken verbatim from
# /etc/init.d/codesyscontrol:17,20,65 of the shipped .deb:
#   EXEC=/opt/codesys/bin/codesyscontrol.bin
#   WORKDIR=/var/opt/codesys
#   CONFIGFILE=/etc/codesyscontrol/CODESYSControl.cfg
#
# The previous CMD did `/etc/init.d/codesyscontrol start` (which forks
# codesyscontrol into the background) and then `exec tail -F ...` on
# the log. That made `tail` the container's PID 1 — codesyscontrol
# crashing did NOT take the container down. Same "Up with no runtime"
# failure mode as cp02. With codesyscontrol as PID 1, a runtime crash
# kills the container → Quadlet/systemd restart fires → reality.
WORKDIR /var/opt/codesys
ENTRYPOINT ["/opt/codesys/bin/codesyscontrol.bin", "/etc/codesyscontrol/CODESYSControl.cfg"]
