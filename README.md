# Embernet CODESYS Control for Linux ARM64 SL

CODESYS Control SL runtime (PLC IEC 61131-3, ARM64) wrapped in a
`debian:bookworm-slim` container for distro-agnostic deployment via
Podman Quadlet on EmberNet edge appliances.

## What this gives you

A self-contained PLC runtime container, deployed via Quadlet + systemd
on a Raspberry Pi (or any aarch64 Linux), exposing:

| Port | Purpose |
|------|---------|
| 1217 | CODESYS Gateway (IDE connection) |
| 4840 | OPC UA server |
| 8080 | Web visualization / HMI |

Demo mode is automatic — the runtime cycles every 30 minutes until you
provision a CodeMeter license. No CodeMeter sidecar in the base image
yet; add it as a follow-up when licensing is needed.

## Why containerize?

The upstream CODESYS Control SL distribution is a CODESYS `.package`
(ZIP) wrapping a Debian `.deb`. Installing the `.deb` directly on
openSUSE MicroOS (or any RPM-based host) is non-viable — and the .deb's
own `postinst` script has a documented container short-circuit (it
skips host-daemon registration when it sees `$CONTAINER=true` or
`/.dockerenv`), confirming that container deployment is the supported
path.

This image:
- Sets `ENV CONTAINER=true` so the postinst skips host registration.
- `dpkg -i --force-depends` the .deb to bypass the
  `Depends: codemeter | codemeter-lite` line (CodeMeter isn't in
  Debian's main repos; demo mode works without it).
- Manages daemon lifecycle via the Quadlet `[Service]` section.
- Pins WG mesh + LAN reachability via `--network host` so operators'
  CODESYS IDE can connect to `<pi-ip>:1217` directly with no NAT.

## Repo layout

```
codesys-linux-arm-64/
├── Containerfile                      # debian:bookworm-slim + .deb install
├── README.md                          # this file
├── .github/workflows/build.yml        # multi-arch CI build + push to ghcr
├── quadlet/
│   ├── embernet-codesys.container     # systemd-managed Podman unit
│   ├── embernet-codesys-config.volume # /etc/codesyscontrol persistence
│   └── embernet-codesys-data.volume   # /var/opt/codesys persistence
└── scripts/
    └── install.sh                     # one-shot operator installer
                                       # (called by deploy-eci-ember-node)
```

## Install on a Pi

The deploy at [Fireball-Red-Team/deploy-eci-ember-node](https://github.com/Fireball-Red-Team/deploy-eci-ember-node)
clones this repo and runs `scripts/install.sh` automatically. To install
manually:

```bash
git clone https://github.com/Embernet-ai/codesys-linux-arm-64.git \
  /opt/embernet/codesys-linux-arm-64
cd /opt/embernet/codesys-linux-arm-64
sudo bash scripts/install.sh
```

The installer pulls `ghcr.io/embernet-ai/codesys-linux-arm-64:latest`
(published on every commit to main), places Quadlet units, and starts
the service. Re-runnable; idempotent.

## Verify

```bash
systemctl status embernet-codesys.service --no-pager
journalctl -u embernet-codesys.service -n 80 --no-pager

# Confirm the runtime is accepting gateway connections
nc -z localhost 1217 && echo "gateway OK"

# Confirm OPC UA is up
nc -z localhost 4840 && echo "opc-ua OK"
```

## Connect from the CODESYS IDE (Windows)

1. CODESYS IDE → Online → Communication Settings
2. Add gateway: `Gateway-Linux`, address `<pi-ip>:1217`
3. Scan network → device `embernet-codesys` appears
4. Click `Set active path` → connect

## Resource budget

Sized for a Pi 4/5 co-tenanting Ignition Edge, K3s agent, and the
ForgeNET network controller:

| Knob | Value | Where |
|------|-------|-------|
| Memory | 384 MiB | Quadlet `Memory=` |
| CPU | 1.0 core | Quadlet `[Service]` `CPUQuota=100%` |
| RT priority | up to 99 | Quadlet `[Service]` `LimitRTPRIO=99` |
| Locked memory | unlimited | Quadlet `[Service]` `LimitMEMLOCK=infinity` |

`LimitRTPRIO` + `LimitMEMLOCK` let the runtime use `SCHED_FIFO` and
`mlock()` for predictable scan-cycle timing — the practical bridge
between containerization and soft-real-time PLC behavior.

Override on a beefier appliance via:

```bash
sudo mkdir -p /etc/containers/systemd/embernet-codesys.container.d
sudo tee /etc/containers/systemd/embernet-codesys.container.d/oversized.conf <<'EOF'
[Container]
Memory=1G
[Service]
CPUQuota=200%
EOF
sudo systemctl daemon-reload
sudo systemctl restart embernet-codesys.service
```

## Licensing (CodeMeter)

The base image installs the `.deb` with `--force-depends`, skipping the
`codemeter | codemeter-lite` dependency. Without CodeMeter the runtime
operates in 30-minute demo cycles — ideal for unlicensed bring-up.

To enable real licensing:

1. Add WIBU SystemSec's apt repo to a forked Containerfile.
2. `apt-get install codemeter-lite`.
3. Drop `--force-depends` from the `dpkg -i` line.
4. Rebuild + push.
5. Mount a CmActLicense file or point at a network CmContainer at
   container start.

## CI

- **Trigger**: push to `main` or `develop`, plus PRs against `main`.
- **Build**: `podman build --platform linux/arm64` (ARM64-only — this
  runtime is ARM64-only).
- **Push**: on push events to main/develop, manifest pushed to
  `ghcr.io/embernet-ai/codesys-linux-arm-64:<branch>`. On main pushes,
  also published as `:latest` and the version tag (currently
  `:4.20.0.0`).
- **Smoke test**: confirms the runtime layout (`/etc/init.d/`,
  `/opt/codesys/`, `/etc/codesyscontrol/`) and that the daemon
  accepts a start signal.
- **Permissions**: workflow has `permissions: packages: write`.

## Source upstream

The actual CODESYS .package is published at this repo's GitHub releases
(`v4.20.0.0` currently), tracking CODESYS GmbH's upstream releases.
Bump `CODESYS_VERSION` in the Containerfile + workflow when
republishing for a new upstream version.
