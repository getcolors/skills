# Pins

## The verified-good set

Running together on a two-node VKE cluster (`vc2-2c-4gb` × 2, region `ams`)
with every acceptance gate passing, including inner isolation probed through
the SOCKS5 listener and the five-disruption suite (both application pods
bounced, both stateful gateway components restarted, one node drain).
**Verified 2026-08-28.**

| Component | Pin |
|---|---|
| VKE control plane | `v1.36.2+1` (live-checked; see rule below) |
| Calico (VKE-shipped CNI) | whatever the VKE release bundles — not separately pinnable |
| `netbird-server` | `netbirdio/netbird-server:0.77.1@sha256:e71f39cefcd90956d818dc4179084fd47d39f0741d1211b818ec640766b5794d` |
| `reverse-proxy` | `netbirdio/reverse-proxy:0.77.1@sha256:d3f5815133542c333e7e7166e19989adcce9afb15443a8de5ecbc87ef528c8f0` |
| NetBird client (SOCKS5 pod) | `netbirdio/netbird:0.77.1@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451` |
| `dashboard` | `netbirdio/dashboard:v2.91.1@sha256:f3eb26c93ca9901a7385e88e12f6ad98d04e075e8817c664d73557fea123875f` |
| `traefik` | `traefik:v3.7.11@sha256:5203c3f39ca70de6790d964624e042463ffbd57715bc82be155cf224c0dd5144` |
| agent base image | `node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5` |
| Claude Code (in the agent) | `2.1.246` — installed with `npm ci` from a committed integrity-hashed lockfile |
| privoxy (primary bridge) | `3.0.34-1` (exact Debian bookworm package) |
| gost (fallback bridge, in-image) | `3.2.6`, release tarball sha256 `b39037b0380ea001fb3c0c28441c2e10bfc694f90682739a65b53e55dce5238b` |
| kaniko (in-cluster build) | `gcr.io/kaniko-project/executor:v1.24.0-debug@sha256:2562c4fe551399514277ffff7dcca9a3b1628c4ea38cb017d7286dc6ea52f4cd` |
| lego (DNS-01, launcher-side) | `5.4.0` (official release binary, checksum-verified, per-arch) |

## The rules that generated it

The specific versions will age out; these constraints are what matter.

### Server, proxy, and client move together — one release train

Unchanged from the single-node build, with one addition: on Kubernetes the
client is a pulled image, not a tarball install, so the **client image
digest** joins the train. Bump all three in one change.

### The VKE version is checked live, never trusted from desired state

VKE retires minors. The pin `v1.35.2+1` was rejected by the live API on
create day (`currently supported: v1.36.2+1, v1.35.6+1, v1.34.9+1`); a
preflight against `GET /v2/kubernetes/versions` before the apply turns a
half-created cluster into a free, exact error. Re-record the pin whenever
the check forces a bump.

### The 0.77.1 client is configured by environment, not flags

`--daemon-addr` and `--log-file` on `service run` parse and do nothing
(verified in-pod, flag before and after the subcommand). `NB_DAEMON_ADDR`,
`NB_LOG_FILE`, `NB_USE_NETSTACK_MODE`, `NB_SOCKS5_LISTENER_ADDRESS`,
`NB_SOCKS5_LISTENER_PORT` work, plus `USER`/`HOME` for `netbird up` under a
passwd-less uid. **On any client bump, re-test whether the flags started
working** — if they did, the env-only doctrine here becomes optional and
this entry should say so.

### kaniko must be the -debug variant

The build context streams over `kubectl exec` stdin into a waiting init
container, which needs a shell; the plain executor image is scratch-based.
The context tarball is deterministic (`tar --sort=name --mtime=@0
--owner=0 --group=0`) so its sha names the Job and the tag, and the deploy
consumes only the digest read back from the registry (HEAD the manifest,
`docker-content-digest`) — tags are never trusted.

### Claude Code installs from a committed lockfile

`npm ci` against an integrity-hashed `package-lock.json` in the package
repository. Bumping `2.1.246` means regenerating that lockfile; `npm ci`
fails loudly on a mismatch, by design. Every model knob stays pinned to
the allowlisted model (six variables — see the single-node skill's pins);
re-enumerate on any Claude Code bump.

### lego per launcher arch, checksum grep anchored

The launcher may be arm64 (this one was). Map `uname -m` to the release
asset name, and anchor the checksums grep to end-of-line: the checksums
file also lists `…tar.gz.sbom.json`, and an unanchored grep feeds
sha256sum a second line that always fails.

### Wildcard certificate: both SANs, still no per-name ACME

Per-name ACME remains defective on reverse-proxy 0.77.1 (the single-node
skill owns that finding and its staging retest condition). On Kubernetes
the same lego order must carry `-d <base> -d '*.<base>'` — Traefik
terminates the bare base name from the same Secret, and a wildcard alone
does not cover it. Verified by the SAN gate on the issued pair.

### Known retest conditions on the next NetBird bump

- flags on `service run` (above);
- whether the embedded proxy peer appears in `/api/peers` (it does not on
  0.77.1 — the network map is the only consumer-visible source of its
  overlay address);
- whether stale embedded-proxy registrations still linger in the network
  map after a proxy restart, and whether the overlay address still churns
  per restart — the whole reconcile-on-drift doctrine hangs on those two;
- whether netstack SOCKS5 still serves hostname CONNECTs via the OS
  resolver (the primary bridge depends on it; the gost fallback exists in
  the companion for the day it stops).
