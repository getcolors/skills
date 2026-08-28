---
name: agent-network-kubernetes
description: Everything a NetBird Agent Network on Kubernetes needs that the single-node build will not tell you — the two-pod netstack/SOCKS5 application (no TUN, no capabilities) whose isolation is NetworkPolicy probed from both sides, and the 0.77.1 client facts only a live VKE converge surfaces. Use on these symptoms - the client binds /var/run/netbird.sock or dials api.netbird.io forever whatever the flags say (service run silently ignores --daemon-addr and --log-file; use NB_* env); "get current user" requires cgo or $USER; no proxy peer in /api/peers though the proxy runs (it is an embedded peer - read the client's network map); the keyless endpoint dies after every reverse-proxy restart (its overlay address churns and stale registrations linger); server crashloop "illegal base64 data at input byte 40" or "could not initialize geolocation service"; lego checksum FAILED on arm64; an isolated pod that "has an IPv6 default route" on VKE. Full symptom index at the top of the body.
---

# NetBird Agent Network on Kubernetes

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim text in `references/failure-catalogue.md`:

- the NetBird client dials `api.netbird.io:443` forever although flags say
  otherwise; `listen unix /var/run/netbird.sock: bind: read-only file
  system`; `Failed to write to log, can't make directories for new logfile:
  mkdir /var/log/netbird`
- `Error: get current user: user: Current requires cgo or $USER set in
  environment` from `netbird up` in a non-root container
- `GET /api/peers` never lists the reverse proxy although it is running and
  the endpoint was minted
- the keyless endpoint stops answering after a reverse-proxy pod restart,
  eviction, or node drain; the client's peer list shows two proxy peers
- `FATL … failed to create field encryptor: decode encryption key: illegal
  base64 data at input byte 40`
- `FATL … could not initialize geolocation service: … lookup
  pkgs.netbird.io: i/o timeout` in a NetworkPolicy-locked namespace
- `sha256sum: WARNING: 1 computed checksum did NOT match` installing lego —
  on arm64, or with a checksums grep that also matches the `.sbom.json` line
- `cannot unmarshal object into Go struct field ExecAction…exec.command of
  type string` applying a manifest whose probe command contains `: `
- the isolated pod "has an IPv6 default route" (VKE dual-stack plumbing) or
  a `kubectl version` refused right after `vultr_kubernetes` created
- `Can't access attributes on a primitive-typed value (string)` on
  `vultr_container_registry.….root_user`

This is the Kubernetes sibling of `agent-network-single-node`: same product
(a keyless, policy-gated LLM endpoint and a network-isolated agent running
headless Claude Code), same control-plane contract — endpoint minted by the
settings POST, setup-PAT exchange, one-off key discipline, fake-key mode,
defective per-name ACME on the pinned build — all of which that skill and
its `references/api.md` own and this one does not repeat. What this skill
carries is the distance between that verified single-node build and the
same claims proven on managed Kubernetes (Vultr VKE), where the agent runs
**unprivileged**: no TUN device, no NET_ADMIN, no kernel WireGuard.

Everything here was verified against a live VKE deployment (sixteen real
converges, 2026-08-28, all acceptance gates green including a
five-disruption suite with a node drain) unless it says otherwise. Where a
claim comes from review rather than a live failure, the entry says so.

## The reference implementation, and why this skill ships no assets

The tested working files — OpenTofu for the cluster and registry, the
manifests, the NetworkPolicy matrix, the converge/bootstrap/acceptance
scripts — live in the
[`getcolors/agent-network-k8s`](https://github.com/getcolors/agent-network-k8s)
Package Skill, covered by its tests and two-backend golden fixtures and
consumed by the `agent-network-k8s-vultr` deployment. This skill carries no
copies of them (Context Skill Standard §3). Read the templates there; read
*why they are shaped that way* here.

## The topology

One VKE cluster, three namespaces. The gateway namespace (`baseline` Pod
Security) runs Traefik behind a TCP-mode Vultr Load Balancer (the only
public surface: TCP 80/443 — no UDP is ever public), the combined
`netbird-server` on a CSI volume, the dashboard, and the reverse proxy in
private mode. The agent namespace (`restricted`) runs the **two-pod
application**:

- the **NetBird client pod**: the stock client image in netstack mode
  (`NB_USE_NETSTACK_MODE`), a userspace WireGuard peer exposing an
  unauthenticated SOCKS5 listener — no TUN, no capabilities, non-root,
  read-only rootfs, state on a small RWO volume so a reschedule reconnects
  without a new key;
- the **agent pod**: headless Claude Code plus a localhost HTTP→SOCKS5
  bridge (Claude Code cannot speak SOCKS5 — it crashes on socks proxy URLs;
  documented upstream, not re-reproduced here). Its only network egress,
  enforced by a default-deny NetworkPolicy with a single allow, is the
  SOCKS5 listener. No ServiceAccount token, no DNS: everything it dials is
  a ClusterIP rendered at converge.

A build namespace runs kaniko once per context (the agent pod has no egress
and managed nodes offer no host docker); the deploy consumes only the
digest read back from the registry.

## Netstack mode: the client the flags don't configure

Four facts about the pinned 0.77.1 client, all live-verified, that decide
whether this design works at all:

1. **`netbird service run` silently ignores `--daemon-addr` and
   `--log-file`** — the flags parse (they are in `--help`) and do nothing:
   the daemon binds `unix:///var/run/netbird.sock` and logs to
   `/var/log/netbird` regardless, which on a read-only rootfs is fatal.
   The `NB_DAEMON_ADDR` and `NB_LOG_FILE` environment variables work.
   Wire the client entirely through `NB_*` env on the pod; the CLI, exec
   probes, and readiness checks then inherit them.
2. **`netbird up` needs `$USER`** when the runtime uid has no passwd entry
   (`restricted` non-root): `get current user: user: Current requires cgo
   or $USER set in environment`. Set `USER` and `HOME` env.
3. **A config file is NOT evidence of enrollment.** The daemon writes
   `default.json` the moment it starts ("not trying to connect when
   configuration was just created"), and a failed first `up` persists the
   default `api.netbird.io` management URL into it — after which every
   later start dials the wrong control plane forever. Trust the daemon's
   status (`NeedsLogin` means no identity), and treat state whose
   management URL is foreign as poison to wipe, not state to resume.
4. **Netstack SOCKS5 DOES serve hostname CONNECTs** — resolved through the
   pod's OS resolver, `/etc/hosts` included. The FaaS doc's "DNS is not
   supported… peers by IP address only" is about the NetBird DNS feature
   (management-pushed zones), not about the listener's own resolution. This
   is what makes the primary bridge work: map the endpoint hostname to the
   proxy's overlay address in the client pod's `hostAliases`, pass the
   hostname through (`--socks5-hostname` semantics), and TLS carries the
   right SNI over the tunnel. The identity boundary is intact either way —
   the only dialable destination is the overlay, and that is probed, not
   assumed.

## The embedded proxy peer, and the endpoint address that churns

The reverse proxy in private mode registers as an **embedded proxy peer**
and **never appears in `GET /api/peers`** — only real clients do. Its
overlay address exists in exactly one consumer-visible place: the network
map management pushes to enrolled peers (`netbird status --json`,
`.peers.details[]`). Three facts follow, each bought with a failed gate:

- **Read the address from an enrolled client**, after enrollment — not
  from the management API, which has no proxies listing (probed:
  `/agent-network/proxies` and `/agent-network/proxy-clusters` are 404).
- **Every proxy pod restart is a new registration with a new overlay
  address.** Observed live across restarts and a node drain:
  `.28.93 → .13.102 → .103.55 → .176.82`. TUN-mode peers would receive the
  updated synthesized DNS zone automatically; a netstack deployment's
  static hostname→overlay mapping goes stale the moment the pod bounces
  and MUST be reconciled (re-read the map, re-render, roll the client) —
  converge is the heal, and acceptance re-checks for drift before every
  probe run.
- **Stale registrations linger in the map** beside their replacement, so
  "exactly one peer" is not a fact the map offers. The synthesized fqdn is
  `proxy-<xid>-<ip-suffix>` and xids are k-sortable: the newest
  registration — the greatest id — is the live proxy. Validate the pick
  end-to-end (a CONNECT through the tunnel) rather than trusting it.

## Isolation is one mechanism probed from two sides

The Docker build had two boundaries; Kubernetes has one mechanism —
NetworkPolicy (VKE ships Calico, which enforces it) — and one honest
listener problem: **NetworkPolicy cannot constrain what a CONNECT names.**
The agent's single egress rule admits the SOCKS5 pod, and the SOCKS5 pod
can dial whatever netstack routes. So acceptance probes both sides, every
converge:

- **outer**: raw TCP from the agent container to the internet (both IP
  families), the API server, kube-dns, the metadata address, and every
  gateway service — all must fail; the SOCKS5 port must succeed (the
  control, so breakage cannot masquerade as isolation);
- **inner**: CONNECTs *through* the listener to the same forbidden set,
  plus hostname-form requests to public names and overlay-adjacent address
  guesses — all must fail; only the proxy's overlay address may answer.

Do not assert route-table shape on managed Kubernetes: VKE pods carry a
unique-local IPv6 address and a link-local default route as dual-stack
plumbing, with public IPv6 unreachable. Reachability per family is the
claim; a "no IPv6 default route" gate fails a healthy, isolated pod.

## What else the live build forced

- **The combined server rejects unpadded base64** for its datastore and
  cookie keys (`illegal base64 data at input byte 40`, a crashloop) — and
  **refuses to boot without its GeoLite database**, fetched from
  `pkgs.netbird.io` on first start. In a locked-down namespace that means
  an explicit DNS + CIDR-bounded 443 egress allowance for the server; the
  single-node build never saw either because its host generation kept
  padding and its docker network had egress.
- **Traefik evaluates matching TCP routers before HTTP routers**, so a
  `HostSNI(*)` passthrough swallows the dashboard and API; match endpoint
  *subdomains only* (`HostSNIRegexp`). One lego DNS-01 order carries
  **both SANs** — a wildcard alone does not cover the bare base name.
  (Adopted from documented precedence during adversarial review, then
  verified by the working deployment's routing.)
- **A freshly created VKE cluster answers its API minutes later**, nodes
  later still — the first `kubectl` is a bounded wait, not a call. VKE
  retires minors: check the pinned version against
  `GET /v2/kubernetes/versions` while failing is still free.
- **Vultr Container Registry**: names are lowercase alphanumerics only,
  and the OpenTofu resource's `root_user` is a `map(string)` —
  `root_user["username"]`, not `root_user[0].username`.
- **The setup key never becomes a Kubernetes Secret** (etcd keeps durable
  copies): it streams over `kubectl exec` stdin into a memory-backed
  volume, profile-scoped on the launcher side so two deployments on one
  workstation cannot revoke each other's key. An enrolled client's state
  volume is its identity; re-enrollment after state loss means removing
  the stale peer record first, or the mint is refused while the pod waits
  for a key that never comes.

For the version set and the rules that generated it, `references/pins.md`.
For symptom-first debugging, `references/failure-catalogue.md`. For the
netstack client contract as observed, `references/netstack.md`. For what a
trustworthy converge checks on Kubernetes, `references/acceptance.md`. For
the control-plane REST contract, the sibling skill's `references/api.md` —
it is the owner; nothing there changed on Kubernetes.
