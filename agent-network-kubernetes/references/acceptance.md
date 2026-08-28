# Acceptance doctrine on Kubernetes

What a trustworthy converge of this topology actually checks, as run green
on the live VKE deployment 2026-08-28. The single-node doctrine — negative
probes paired with a control that must succeed, denial classes at zero
upstream cost, the external pre-identity 403, limits read back — carries
over whole; this records what Kubernetes changes or adds.

## Isolation is probed from both sides of the listener

NetworkPolicy is one mechanism with an honest gap: it constrains which pod
the agent may reach, not what a CONNECT through that pod may name. So:

- **Outer** (around the SOCKS5 pod): raw TCP from the agent container to
  public v4 AND v6 addresses, the metadata address, the API server,
  kube-dns, and every gateway ClusterIP — all must fail — plus the control:
  the SOCKS5 port must answer, or the failures above prove breakage, not
  isolation.
- **Inner** (through it): CONNECTs to the same forbidden set, hostname-form
  CONNECTs to public names (the primary bridge's real escape surface), and
  overlay-adjacent address guesses — all must fail; only the proxy's
  overlay address may answer, and that success doubles as the inner
  control.

Do not assert route-table shape: VKE pods carry a ULA and a link-local v6
default route as CNI plumbing (see the failure catalogue's
"verification that would have lied"). Reachability per family is the claim.

Assert the absence trio for the setup key: revoked server-side, staging
file gone, and **no Secret with a setup-shaped name anywhere in the
cluster** — the key must never have become a Kubernetes Secret (etcd keeps
durable copies), so its absence there is asserted by name, not assumed
from the code path.

## Drift is checked before every probe run

The endpoint's overlay mapping is static state in a netstack deployment,
and the proxy's overlay address churns on every restart. Every probe run
starts by re-reading the client's network map (newest registration) and
comparing against the rendered mapping; on mismatch the run fails with
"re-run create" rather than letting a dead mapping shape the probe
results. The converge itself is the heal: it re-reads, re-renders, and
rolls the client.

## The disruption suite

Run once per deployment (recorded in profile state), each step followed by
the post-disruption gates (outer + inner isolation, tunnel, keyless call):

1. delete the agent pod (reschedule);
2. delete the SOCKS5 pod — the state volume re-attaches and the client
   reconnects **without a new key**, which is the whole one-off-key design
   proven;
3. restart the reverse proxy — the overlay address changes; reconcile the
   mapping before regating (this step, unreconciled, is a guaranteed fail);
4. restart the combined server — reconcile likewise (usually a no-op);
5. drain the node hosting the application, under an **unconditional trap
   that uncordons the exact node and asserts every node Ready even when a
   gate fails mid-suite** — a failed run must not leave a small cluster
   silently half-capacity. The drain evicts the proxy too, so it implies
   step 3's reconcile.

## The external probe, honestly scoped

The outside-the-overlay probe (endpoint must answer the bare pre-identity
403; an upstream 401 means key injection served an unauthenticated caller)
runs from the launcher with a scrubbed environment (`env -i`), asserts no
NetBird/WireGuard interface exists, asserts the route to the LB rides no
tunnel interface, and pins the connection to the LB address with
`--resolve`. A *connected* clean network namespace would be stronger but
requires root veth/NAT plumbing a launcher cannot assume; this is the
strongest unprivileged form, and the limitation is stated rather than
papered over.

## Gates that must fail closed on their own bugs

Two probe-construction lessons from the live run, both in the failure
catalogue: capture curl's `%{http_code}` without appending a fallback that
doubles it (`000000`), and never demand of the platform what it does not
promise ("exactly one proxy peer" — stale registrations linger; assert
newest-registration selection validated end-to-end instead).
