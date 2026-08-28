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

## What delete would check — unverified

The teardown order (workloads → PVCs waiting for CSI volumes → the LB
Service waiting for the LB → namespaces → provider-side verification of
volumes and LB via the DO API → adopt-mode repository deletion) is
implemented and reviewed, with provider-side cleanup deliberately
independent of cluster reachability — but **no delete has run against the
live deployment**. Treat every claim in that flow as design intent until
one has.
