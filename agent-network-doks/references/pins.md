# Pins

## The verified-good set

Running together on a two-node DOKS cluster (`s-2vcpu-4gb` × 2, region
`ams3`, `ha = false`, legacy non-VPC-native networking) with every
acceptance gate passing — inner isolation probed through the SOCKS5
listener, the LB firewall verified through the DO API, and the
five-disruption suite including a node drain. Six create runs, three full
passes, the last two on the pinned payload. **Verified 2026-08-28.**

| Component | Pin |
|---|---|
| DOKS control plane | `1.36.3-do.2` (slug form; live-checked, see rule below) |
| Cilium (DOKS-shipped CNI) | whatever the DOKS release bundles — not separately pinnable |
| DOCR subscription tier | `basic` (create mode; the tier key is create-mode-only) |
| OpenTofu `digitalocean` provider | constraint `~> 2.0` |
| OpenTofu `time` provider | constraint `~> 0.12` (`time_rotating` for credential rotation) |
| `netbird-server` | `netbirdio/netbird-server:0.77.1@sha256:e71f39cefcd90956d818dc4179084fd47d39f0741d1211b818ec640766b5794d` |
| `reverse-proxy` | `netbirdio/reverse-proxy:0.77.1@sha256:d3f5815133542c333e7e7166e19989adcce9afb15443a8de5ecbc87ef528c8f0` |
| NetBird client (SOCKS5 pod) | `netbirdio/netbird:0.77.1@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451` |
| `dashboard` | `netbirdio/dashboard:v2.91.1@sha256:f3eb26c93ca9901a7385e88e12f6ad98d04e075e8817c664d73557fea123875f` |
| `traefik` | `traefik:v3.7.11@sha256:5203c3f39ca70de6790d964624e042463ffbd57715bc82be155cf224c0dd5144` |
| agent base image | `node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5` |
| Claude Code (in the agent) | `2.1.246` (`npm ci` from the committed integrity-hashed lockfile) |
| privoxy (primary bridge) | `3.0.34-1` |
| gost (fallback bridge, in-image) | `3.2.6`, tarball sha256 `b39037b0380ea001fb3c0c28441c2e10bfc694f90682739a65b53e55dce5238b` |
| kaniko (in-cluster build) | `gcr.io/kaniko-project/executor:v1.24.0-debug@sha256:2562c4fe551399514277ffff7dcca9a3b1628c4ea38cb017d7286dc6ea52f4cd` |
| lego (DNS-01, launcher-side) | `5.4.0` |

The NetBird release train, the lockfile discipline, the kaniko `-debug`
requirement, the lego checksum anchoring, and the both-SANs wildcard rule
are unchanged from the VKE sibling — `agent-network-kubernetes`
`references/pins.md` owns them and their retest conditions. Below is only
what DigitalOcean adds.

## The rules that generated it

### The DOKS slug is checked live, and the changelog is not the slug

The API accepts only `x.y.z-do.v` (`1.36.3-do.2` accepted on create day);
the DOKS changelog sometimes prints `x.y.z.do-v`, which is not a slug
(documentation-sourced; the rejection was not reproduced live — on this
build the pin was current, so the preflight against
`GET /v2/kubernetes/options` → `options.versions[].slug` passed silently).
DOKS supports the three most recent minors for new clusters; re-record the
pin whenever the preflight forces a bump.

### Subnets are never pinned — they are read back

No `cluster_subnet`/`service_subnet` in desired state, ever. The values the
live cluster allocated (`10.110.0.0/16`-space pods, `10.111.0.0/16`-space
Services) are recorded here as evidence, **not as pins**: another cluster
may receive different ranges, which is exactly why the companion reads them
back per converge. On any DOKS networking change (e.g. VPC-native becoming
the API default), re-verify that `cluster_subnet` and `service_subnet` are
still populated on the resource in legacy mode.

### Registry credentials: asymmetric lifetimes, rotation untested over time

Write credential `expiry_seconds = 93600` (26h) rotated daily; read-only
pull credential `expiry_seconds = 7776000` (90d) rotated every 30 days via
`time_rotating` + `replace_triggered_by`. Both were minted and used live
(kaniko push, kubelet pull); **no rotation boundary has been crossed yet**.
Retest condition: the first converge more than 24h after create must
recreate the write credential and still build; a converge more than 30 days
out must roll the pull Secret without an ImagePullBackOff window.

### `ha = false` is explicit, and its premise is open

Review asserted DOKS 1.36+ enables the paid HA control plane when `ha` is
omitted. Unverified. The explicit `false` stands regardless; if you remove
it, check the first plan for an HA line item before applying.

### Known retest conditions on the next DOKS/provider bump

- whether legacy (no-subnet) cluster creation still allocates
  non-`10.244.0.0/16` ranges — the read-back design assumes nothing, but
  the failure-catalogue entry's evidence dates from this allocation;
- whether `kube_config[0].raw_config` remains the kubeconfig attribute
  shape on the `digitalocean` provider;
- whether `REGIONAL` remains the LB type this topology wants (the
  `REGIONAL_NETWORK` type existed at build time and was deliberately not
  chosen; its IPv6 and health-check behavior were never tested here);
- whether DOCR still exposes `manifest_digest` on
  `GET /v2/registry/<r>/repositories/<repo>/tags`, which the digest-only
  deploy depends on;
- the Professional multi-registry cap (10 — never exercised: this account
  ran the zero-registries create path).
