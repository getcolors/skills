# Acceptance doctrine on DOKS

What a trustworthy converge adds on DigitalOcean, as run green on the live
deployment 2026-08-28 (three full passes; the five-disruption suite with
the node drain ran once and is recorded in profile state). The Kubernetes
doctrine — isolation probed from both sides of the SOCKS5 listener with
paired controls, drift checked before every probe run, the external
pre-identity 403 honestly scoped, gates that fail closed on their own bugs
— is owned whole by `agent-network-kubernetes` `references/acceptance.md`
and carries over unchanged. This records only the DOKS delta.

## Prove the CNI before trusting it with secrets

DOKS ships Cilium and the docs say it enforces NetworkPolicy. The converge
turns that into an observation **before any secret or provider credential
enters the cluster**: a throwaway namespace with default-deny plus one
scoped allow, two pods from the pinned NetBird client image (alpine
busybox `nc` is present), three probes — the single allowed path must
admit, the internet must be denied, cross-namespace must be denied. A
cluster that fails the canary gets nothing else.

The pass marker is **cluster-UID-bound** (kube-system UID compared on
every converge): a replaced cluster under the same profile re-proves
enforcement. Deliberately NOT proven by the canary: `ipBlock.except`
semantics — the allow side of the private-range carve-outs is exercised
live every converge anyway (the server's GeoLite fetch and the proxy's
upstream relay both require it), the agent-side denials are gates 1/1b's
job, and the residual case (a private-range dial from the proxy pod
itself) is the same documented honest limit the VKE sibling carries.

## Verify the subnets you read back — both of them

The read-back `cluster_subnet` and `service_subnet` are the authority for
everything CIDR-derived, and the converge asserts both against life: a
running pod's IP must sit inside the cluster subnet, and a live ClusterIP
(the `kubernetes.default` Service works) inside the service subnet. A
sampled address outside its subnet means the trusted-proxy ranges rendered
earlier are silently wrong — fail there, not at the first mysterious
PROXY-protocol rejection.

## The LB firewall is verified through the API, not probed

`loadBalancerSourceRanges` is enforced by the cloud controller as LB
firewall rules. An open (`0.0.0.0/0`) deployment cannot prove denial by
probing — every probe succeeds either way — so the gate reads
`GET /v2/load_balancers`, selects the LB by its address, and compares the
`cidr:` entries of `.firewall.allow[]` against desired state, tolerating
controller-managed rules rather than demanding whole-firewall equality.
Open desired state accepts an absent or empty firewall as the open
configuration (that branch is the live-verified one; the
restricted-equality branch is implemented but not yet exercised by a
restricted deployment). The closed-ports probe (8443/9090/9000 refused at
the LB) still runs — it tests exposure, which probing can prove.

## Retry asymmetry: positive controls yes, denials never

Two timing windows on this platform produce false negatives in positive
checks — the post-restart 502 through Traefik, and the settling peer path
after a client roll (both in the failure catalogue). The doctrine that
absorbed them without weakening anything: **positive controls and
first-calls-after-restart get bounded retries; denial probes stay
single-shot strict.** A retried denial would hide a real hole; a
single-shot positive control condemns healthy deployments. State which
kind every new probe is before writing it.

## Disruption-suite preflights the managed platform demands

Before deliberately breaking things: every node Ready and none cordoned —
a suite that starts during DOKS maintenance blames its own disruptions for
someone else's. After the drain: wait (bounded) for VolumeAttachments to
leave the drained node before judging the application's rollout — RWO
volumes move only after CSI detach, and a slow detach otherwise surfaces
as a rollout timeout blamed on the application. Both ran live on the
passing drain; the counterfactual paths (a suite refused mid-maintenance,
a detach that actually stalled) have not been observed.

## What delete checks — verified 2026-08-29

One full guarded delete ran against the live deployment (create-mode
registry), exit 0, zero warnings:

- the teardown order held — workloads, then PVCs with a bounded wait for
  the CSI volumes to LEAVE THE ACCOUNT, then the LB Service with a wait
  for the LB to leave, then namespaces (99s in-cluster total);
- the DO API confirmed both Kubernetes-managed billables — block volumes
  and the load balancer — **absent at the provider** before the destroys,
  which is the whole point of tearing down in-cluster first: both are
  invisible to the infrastructure state, and destroying the cluster first
  would orphan them;
- the DNS and infrastructure destroys are fast (seconds — DOKS cluster and
  registry deletion are async at the API), so the independent post-delete
  audit matters: zero clusters, volumes and LBs, no registry, both names
  unresolvable;
- the one-run `COLORS_PAR_COMPUTE_PREVENT_DESTROY=false` override rendered
  `prevent_destroy = false` for exactly that run, leaving the committed
  guard intact;
- local cleanup removed the kubeconfig, state, lego (ACME account and
  certificate keys), and proofs — copy the proof artifacts out first if
  you want them.

Still unverified: adopt-mode teardown, where the registry survives and the
profile repository is deleted through the API instead — that branch has
never run.
