---
name: agent-network-doks
description: 'The DigitalOcean distance from the VKE-verified NetBird Agent Network on Kubernetes - what only a live DOKS converge surfaces. Use on these symptoms - pod IPs in 10.110.x and ClusterIPs in 10.111.x although every doc says DOKS pods default to 10.244.0.0/16, so trusted-proxy CIDRs rendered from that assumption are silently wrong; ''Error from server (NotFound) ... namespaces not found'' from kubectl apply --dry-run=server on a multi-doc file whose first document creates that namespace; ''curl (22) ... 502'' on the first management call right after rollout status says the restarted server is Ready; a SOCKS5 positive control probe failing minutes after the client pod rolled while the identical probe answers later; DOCR refusing a second registry (account-scoped, tier-limited, subscription account-global); reading a pushed image digest back through the DO API tags manifest_digest; HTML-escaped quotes in rendered YAML manifests; kube_config[0].raw_config vs a base64 kubeconfig string. Full symptom index in the body.'
---

# NetBird Agent Network on DigitalOcean Kubernetes (DOKS)

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim text in `references/failure-catalogue.md`:

- pod IPs in `10.110.x.x` and Service ClusterIPs in `10.111.x.x` on a DOKS
  cluster although documentation and community answers say pods default to
  `10.244.0.0/16` — and every CIDR you rendered from that assumption
  (`trustedHTTPProxies`, `NB_PROXY_TRUSTED_PROXIES`, NetworkPolicy rows) is
  silently wrong
- `Error from server (NotFound): error when creating "...yaml": namespaces
  "..." not found` from `kubectl apply --dry-run=server` on a manifest whose
  own first document creates that namespace
- `curl: (22) The requested URL returned error: 502` from the first
  management-API call immediately after `kubectl rollout status` reported
  the restarted server Ready
- a positive control probe through the netstack SOCKS5 listener returns
  `000` shortly after the client pod was rolled, while the identical probe
  answers minutes later — and the run condemned a healthy deployment
- DOCR: a second `digitalocean_container_registry` cannot exist on
  Starter/Basic (registries are account-scoped, tier-limited, and the
  subscription is account-global)
- reading a pushed image's digest back from DOCR without a docker client
  (`GET /v2/registry/<registry>/repositories/<repo>/tags` →
  `manifest_digest`)
- `loadBalancerSourceRanges: [&quot;0.0.0.0/0&quot;]` — HTML-escaped quotes
  in a rendered manifest (green scaffold templating)
- the DOKS changelog names a release `x.y.z.do-v` but the API only accepts
  the slug form `x.y.z-do.v`
- `digitalocean_kubernetes_cluster` kubeconfig is
  `kube_config[0].raw_config` — structured, not Vultr's base64 string

This is the DigitalOcean sibling of `agent-network-kubernetes`: same
product (a keyless, policy-gated LLM endpoint and a network-isolated agent
running headless Claude Code, as a two-pod netstack/SOCKS5 application on
managed Kubernetes), same control-plane contract, and that skill — plus
`agent-network-single-node` beneath it — owns everything provider-neutral:
the 0.77.1 netstack client contract (NB_* env, `$USER`, poisoned-config
discipline), the embedded proxy peer whose overlay address churns and lives
only in the client's network map, Traefik's subdomain-only passthrough, the
one-order-two-SANs wildcard, create-once secrets, the streamed one-off
setup key, and the two-sided isolation doctrine. **None of that is repeated
here.** What this skill carries is the distance between the VKE-verified
build and the same claims proven on DOKS.

Everything here was verified against a live DOKS deployment (six real
create runs, 2026-08-28, three of them full passes with every acceptance
gate green including the five-disruption suite and a node drain; one full
guarded delete, 2026-08-29, exit 0 with the provider confirming volumes,
LB, cluster, registry and DNS absent) unless the entry says otherwise.
Adopt-registry mode and long-term credential rotation have **not** run
against the live platform; every claim about them is labeled.

## The reference implementation, and why this skill ships no assets

The tested working files — OpenTofu for the cluster and registry (both
modes), the manifests, the Cilium canary, the converge/bootstrap/acceptance
scripts — live in the
[`getcolors/agent-network-doks`](https://github.com/getcolors/agent-network-doks)
Package Skill (green only), covered by its tests and two-backend golden
fixtures and consumed by the `agent-network-doks-digitalocean` deployment.
This skill carries no copies of them (Context Skill Standard §3). Read the
templates there; read *why they are shaped that way* here.

## Subnets are outputs, and the documented default is not what you get

The single highest-leverage DOKS fact this build bought: **do not render
any CIDR from an assumed pod range.** The plan originally carried
`10.244.0.0/16` as desired state — the value the VKE build used, the value
DO's own community answers give for DOKS. The live cluster allocated pods
from `10.110.0.0/16`-space and Services from `10.111.0.0/16`-space
(observed: pod IPs `10.110.0.2`–`10.110.0.125`, ClusterIPs
`10.111.19.142`, on a cluster created with neither `cluster_subnet` nor
`service_subnet` supplied). Had the assumption shipped, the server's
`trustedHTTPProxies` and the proxy's `NB_PROXY_TRUSTED_PROXIES` would have
silently excluded Traefik — PROXY-protocol trust broken while every pod
stays green.

The working design: supply no subnets (that is the deliberately-accepted
legacy, non-VPC-native mode — supplying `cluster_subnet` through the API
requires a distinct `service_subnet` and opts into VPC-native account
overlap constraints; automatic non-overlapping allocation is a Control
Panel behavior, not an API one — adopted from adversarial review, then
proven by the working cluster), read `cluster_subnet` and `service_subnet`
back from the resource, persist them as launcher state, and substitute a
`__POD_CIDR__` placeholder at converge. Acceptance then asserts membership
both ways: a live pod IP inside the read-back cluster subnet AND a live
ClusterIP inside the read-back service subnet.

## DOCR: account-scoped, tier-limited, one subscription

A "deployment-owned registry" cannot be unconditional on DigitalOcean the
way it was on Vultr. Registries are account-scoped; Starter/Basic allow
one, Professional up to its documented cap (10 — from review and API docs;
the multi-registry branch is **not live-verified**, this account had zero
registries and the create path ran); the subscription tier is
account-global and must never be mutated by a deployment. The companion
implements adopt-or-create keyed on one optional name key, with the tier
key create-mode-only, a capacity preflight that checks the profile
repository FIRST in adopt mode (reuse after a partial converge is not
allocation), and teardown that deletes exactly the profile repository —
never an adopted registry. Teardown ran live 2026-08-29 in CREATE mode —
the registry fell to the tofu destroy, provider-confirmed — while adopt
mode (including its API-side repository deletion) remains **implemented
and reviewed, not live-run**.

Three registry facts that are live-verified:

- **Credentials are registry-wide** (no repository scoping exists) and come
  from `digitalocean_container_registry_docker_credentials` as a complete
  docker `config.json`. The companion keeps them asymmetric: a short-lived
  write credential whose cluster Secret exists only while kaniko builds
  (EXIT-trapped), and a long-lived read-only pull credential re-applied
  every converge — a node replacement weeks later still has to pull.
  Rotation-over-time (`time_rotating` + `replace_triggered_by`) is wired
  but has not yet crossed a rotation boundary live.
- **The digest read-back needs no docker client**:
  `GET /v2/registry/<registry>/repositories/<repo>/tags` returns
  `manifest_digest` per tag. Both paths verified live: after a kaniko push,
  and as the cache check that skips an unchanged build.
- **kaniko pushes to DOCR** with that provider-minted `config.json`
  mounted as `/kaniko/.docker/config.json` — the VKE build's streamed-
  context/digest-only design carries over unchanged.

## The load balancer, pinned and verified through the API

`service.beta.kubernetes.io/do-loadbalancer-type: "REGIONAL"` and
`do-loadbalancer-protocol: "tcp"` are set explicitly — never left to
version-dependent defaults — and `do-loadbalancer-name` carries the compute
name so teardown and acceptance can find the LB in the account.
`digitalocean-http-sources` renders into
`Service.spec.loadBalancerSourceRanges`, and acceptance verifies the
resulting **LB firewall through the DO API** (`GET /v2/load_balancers`,
`.firewall.allow[]` `cidr:` entries): an open (`0.0.0.0/0`) deployment
cannot prove denial by probing, so the API listing is the gate, with an
absent/empty firewall accepted as the open configuration. The
restricted-sources equality branch is implemented but **not
live-exercised** (the verified deployment ships open, like its Vultr
sibling).

## Ready is the kubelet's opinion, not the gateway's

Two timing truths, both bought with failed gates:

- **A restarted `netbird-server` answers 502 through Traefik after its
  rollout completes.** `kubectl rollout status` returning is not
  management-plane reachability; the first API call after any server
  restart needs a bounded retry (the companion retries the initial
  settings read 30×5s). This killed a disruption-suite run at the
  server-restart step.
- **A freshly rolled client pod's peer path is still settling** (ICE
  renegotiation) for a window after its readiness probe passes. A
  single-shot positive control through the SOCKS5 listener can land in
  that window and condemn a healthy deployment — the same probe answered
  minutes later in both CONNECT forms. Doctrine: positive controls retry
  bounded; denial probes stay single-shot strict (any success is an
  immediate fail). The asymmetry is the point.

## Cluster and manifest mechanics

- **`kubectl apply --dry-run=server` cannot validate namespaced objects
  whose namespace its own file creates** — the dry run does not persist the
  namespace. Apply namespaces for real first, then dry-run the rest. (This
  is why the companion applies `namespaces.yaml` separately, and why its
  Cilium canary applies its namespace before the dry-run-guarded rest.)
- **The Cilium canary**: DOKS ships Cilium, and the docs say it enforces
  NetworkPolicy; the companion proves it per cluster before any secret
  lands — a throwaway namespace, default-deny plus one scoped allow, three
  probes (allowed path admits, internet denied, cross-namespace denied),
  using the pinned NetBird client image for both pods (alpine busybox `nc`
  is present). The pass marker is **cluster-UID-bound** (kube-system UID):
  a replaced cluster under the same profile re-proves enforcement —
  a workstation-scoped marker would hand secrets to an unproven cluster
  (found in cross-inspection, and the re-run was live-tested).
- **The kubeconfig contract is structured**:
  `digitalocean_kubernetes_cluster.….kube_config[0].raw_config`, wrapped in
  `base64encode()` to keep the launcher's decode path identical to the VKE
  sibling's. Indexing it like Vultr's base64 string fails.
- **`ha = false` is set explicitly.** Review claimed DOKS 1.36+ defaults to
  the paid HA control plane on omission; that premise is **unverified** —
  the explicit `false` costs nothing and closes the question.
- **DOKS version slugs** are `x.y.z-do.v` (`1.36.3-do.2` accepted live);
  the changelog sometimes prints `x.y.z.do-v`, which the API rejects
  (documentation-sourced; the rejection was not reproduced). The companion
  preflights the pin against `GET /v2/kubernetes/options` — on this build
  the pin was current, so the rejection path ran only on VKE (see the
  sibling skill).
- **The disruption suite grew DOKS preflights**: refuse to start with a
  NotReady or cordoned node (maintenance windows), and after the drain wait
  for VolumeAttachments to leave the node before judging the application's
  rollout — RWO volumes move only after CSI detach. The drain passed live
  with both; the counterfactuals are untested.

For the version set and the rules that generated it, `references/pins.md`.
For symptom-first debugging, `references/failure-catalogue.md`. For what a
trustworthy converge adds on DOKS, `references/acceptance.md`. For the
netstack client contract, the embedded-proxy-peer doctrine, and the
control-plane REST contract, the sibling skills own them; nothing there
changed on DigitalOcean.
