# Failure catalogue

Every entry was hit on a real converge of the live DOKS Agent Network
deployment (netbird-server/reverse-proxy/client 0.77.1, DOKS `1.36.3-do.2`,
2026-08-28, six create runs) — except the entries labelled otherwise.
**Search for your symptom string first** — most are verbatim error text.
The provider-neutral catalogue (netstack client, embedded proxy peer,
combined server, TLS/edge) lives in `agent-network-kubernetes`
`references/failure-catalogue.md`; nothing there is repeated here.

## Contents

- [Networking the platform decides](#networking-the-platform-decides)
- [Registry and images](#registry-and-images)
- [Timing: Ready is not reachable](#timing-ready-is-not-reachable)
- [Cluster and manifest mechanics](#cluster-and-manifest-mechanics)
- [Workspace tooling](#workspace-tooling)

---

## Networking the platform decides

### Pod IPs are in 10.110.x, ClusterIPs in 10.111.x — not the documented 10.244.0.0/16

**Symptom.** Every reference you find — DO community answers, tutorials,
the VKE sibling's own convention — says DOKS pods live in `10.244.0.0/16`.
Your live cluster's pods are at addresses like `10.110.0.57`, its Services
at `10.111.19.142`. Anything rendered from the assumption — the server's
`trustedHTTPProxies`, the proxy's `NB_PROXY_TRUSTED_PROXIES`, CIDR rows in
NetworkPolicies — no longer describes the cluster, and PROXY-protocol
trust degrades silently while every pod stays Ready.

**Cause.** A DOKS cluster created through the API/provider with neither
`cluster_subnet` nor `service_subnet` (legacy, non-VPC-native mode) gets
platform-allocated ranges that are not the folklore default. Observed
live; a different cluster may receive different ranges.

**Fix.** Treat both subnets as **outputs**: read `cluster_subnet` and
`service_subnet` back from the `digitalocean_kubernetes_cluster` resource,
persist them launcher-side, substitute at converge (the companion uses a
`__POD_CIDR__` placeholder), and assert membership of a live pod IP and a
live ClusterIP against the read-back values before trusting anything
rendered from them. Never carry a pod-CIDR key in desired state.

Related, from review (not live-reproduced): supplying `cluster_subnet`
through the API requires a distinct non-overlapping `service_subnet` and
opts into VPC-native constraints against every VPC and VPC-native cluster
on the team; automatic non-overlapping allocation is a Control Panel
behavior only.

## Registry and images

### A second registry cannot be created — and "rename it" is not a recovery

**Symptom.** Create mode fails its preflight (or, without one, the
`digitalocean_container_registry` apply would fail) because the account
already has a registry. Changing the registry *name* changes nothing.

**Cause.** DOCR registries are account-scoped and tier-limited — one on
Starter/Basic, a documented cap (10) on Professional — and the
subscription tier is **account-global**. The limit is the account, not the
name. (Tier-limit semantics from adversarial review and API docs; this
build's account had zero registries, so only the zero→create path ran
live.)

**Fix.** Adopt-or-create as explicit modes: an optional
`digitalocean-registry-name` adopts the existing registry (a data source —
never created, never destroyed; only the profile-named repository inside
it is deployment-owned), and the create-mode tier key becomes an error in
adopt mode. Recovery from a failed create is BOTH setting the name key AND
removing the tier key. In adopt mode, check the profile repository before
counting capacity — an existing repository from a partial converge is
reuse, not allocation. No path may mutate the account subscription.

### Reading the pushed digest without docker

**Symptom.** The deploy consumes images by digest only, but the launcher
has no docker client, and DOCR's docker-registry-v2 endpoint wants a token
dance for a bare HEAD.

**Fix (verified live, both paths).** The DO API serves it directly:

```
GET https://api.digitalocean.com/v2/registry/<registry>/repositories/<repo>/tags
```

with the account token; each tag entry carries `manifest_digest`. Works
after a fresh kaniko push and as the cache check that decides whether an
unchanged context needs building at all. Registry-wide credentials
(`digitalocean_container_registry_docker_credentials`, a complete docker
`config.json`) are only needed by kaniko's push and the kubelet's pull.

## Timing: Ready is not reachable

### `curl: (22) The requested URL returned error: 502` right after the server rollout completes

**Symptom.** During a reconcile that follows a `netbird-server` restart:

```
partitioned roll out complete: 1 new pods have been updated...
curl: (22) The requested URL returned error: 502
```

The very first management-API call after `kubectl rollout status` returns
dies, and under `set -e` it takes the whole converge with it. Hit live at
the disruption suite's server-restart step.

**Cause.** `rollout status` reports the kubelet's readiness; the
management plane behind Traefik answers 502 for a short window after that
while it warms. Ready is the kubelet's opinion, not the gateway's.

**Fix.** Bounded retry on the first management call of any script that can
run after a server restart (the companion retries its initial settings
read 30×5s). Do not widen every call — one retried entry point is enough,
and blanket retries would mask real outages.

### The overlay answers nothing through SOCKS5 — but only for a while

**Symptom.**

```
FAIL: the overlay address is not reachable through SOCKS5; the denials above are breakage
```

from an isolation gate's positive control, minutes after the client pod
was rolled onto a new endpoint mapping — while the identical probe (both
CONNECT forms: IP-literal without SNI, and hostname via `--resolve`)
answers fine when re-run by hand shortly after.

**Cause.** Transient: the freshly rolled client's peer path is still
settling (ICE renegotiation) after its readiness probe passes, and the
single-shot control landed at the tail of a probe sequence whose denial
timeouts had consumed the settling window. Not a Cilium defect, not a
netstack defect — the same converge's earlier hostname probe through the
same listener had already succeeded.

**Fix.** Positive controls retry, bounded (the companion: 6 attempts);
denial probes stay single-shot strict, because for them any success is an
immediate, meaningful failure. The asymmetry is deliberate: a flaky
positive control must not condemn a healthy deployment, and a retried
denial probe would hide a real hole.

## Cluster and manifest mechanics

### `Error from server (NotFound): ... namespaces "..." not found` from a server-side dry run

**Symptom.**

```
Error from server (NotFound): error when creating "/tmp/an-canary.yaml": namespaces "agent-network-canary" not found
```

repeated once per namespaced object, from
`kubectl apply --dry-run=server` on a multi-document file whose FIRST
document creates that very namespace.

**Cause.** The server-side dry run does not persist anything — including
the namespace the later documents need — so every namespaced object in the
same file fails admission.

**Fix.** Apply the namespace for real first, then dry-run-guard the rest.
This is the same reason the deploy applies `namespaces.yaml` separately
before every other manifest.

### The canary pass marker must be cluster-bound

**Symptom** (found in cross-inspection, fix live-tested, the failure mode
itself never suffered live): a NetworkPolicy-enforcement canary records
its pass as a bare launcher-side file; the cluster is later replaced under
the same profile; the new, unproven cluster receives secrets without any
enforcement proof.

**Fix.** Record the kube-system namespace UID in the marker and compare on
every converge — a replaced cluster re-runs the canary (verified: the
marker-format change forced a live re-run against the same cluster, which
passed and re-recorded).

### `kube_config` is structured, not a base64 string

**Symptom.** Code ported from the Vultr provider treats the kubeconfig
output as a base64 string and decodes garbage, or indexes a string as a
list.

**Fix.** `digitalocean_kubernetes_cluster.<name>.kube_config[0].raw_config`
is the document; wrap it in `base64encode()` if the consumer expects the
Vultr shape (the companion does, keeping one decode path across siblings).
Adopted from review; verified by every converge's working kubeconfig.

## Workspace tooling

### `loadBalancerSourceRanges: [&quot;0.0.0.0/0&quot;]`

**Symptom.** A rendered manifest carries HTML entities where quotes should
be; `kubectl apply` rejects the document or the field parses wrongly.

**Cause.** The green scaffold template engine HTML-escapes substituted
values — quotes included. Only surfaces when authoring a package, not when
operating a deployment.

**Fix.** Keep quotes out of substituted values: render the list as an
unquoted YAML flow sequence (`[0.0.0.0/0]` — valid YAML for CIDR scalars)
and give scripts a space-joined variant they rebuild JSON from with
`jq -R`.
