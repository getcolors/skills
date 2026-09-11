# Acceptance doctrine

What this stack proves, how, and — more usefully — which reassuring results
mean nothing.

The gates live in the companion package (`github.com/getcolors/automq`) as
`smoke.sh` (on the hosts) and `acceptance.sh` (from the workstation). This file
is the reasoning; it carries no copies.

## The ordering rule

On-host gates run **before** the storage readiness marker is written. The
marker means "this cluster was proved", and a later converge trusts it. Writing
it when the containers start would make it mean "something was launched".

## What each gate is defending against

### On the hosts

| Gate | Defends against |
|---|---|
| Three brokers in cluster metadata | Processes that started but never registered |
| `kafka-metadata-quorum describe --status`: 3 voters **and a leader** | A quorum that lists voters while electing nobody. Static voters stay listed when dead — the leader is the part that carries information |
| N records produced and consumed back, exact match | A broker that accepts writes it cannot serve |
| Objects present in the **data** bucket | The whole architecture. Without this the cluster could be writing to local disk and every other gate still passes |
| Objects present in the **ops** bucket | Ops path silently disabled |
| Wrong password refused; unauthenticated connection refused | An endpoint that accepts everything passes every other gate in the file |
| Client principal denied a cluster-level operation, and denied a topic outside its prefix | Authentication mistaken for authorization |

### From the workstation

| Gate | Defends against |
|---|---|
| Each public name resolves and completes a **verified** TLS handshake | A certificate that exists on disk but is not what the port serves |
| `kcat` over SASL_SSL lists all brokers and round-trips records | Something that works only from inside the VPC |
| Wrong password refused *at the public endpoint* | An internal-only auth boundary |
| Client principal cannot write outside its prefix | ACLs that exist but are not enforced on the path clients use |
| **Targeted** failover (below) | The failover gate that proves nothing |
| Consumer-group offsets survive the outage | RF=1 `__consumer_offsets` losing a group's position |
| A restarted controller re-authenticates and the quorum recovers | A controller mechanism that only works at genesis |
| p99 produce latency, reported not asserted | Pretending a cross-provider storage tier is free |

## The two gates that are easy to fake

**Failover.** Producing unkeyed records to a six-partition topic and killing a
broker can pass without ever touching the broker that died. The gate must work
from the leadership map: read which node leads which partition, pick the victim
from that, produce keyed records to exactly that partition, then kill it.

Do not fix the victim to a particular node index either. Leadership drifts
after an earlier failover, so "kill node 2" fails with *no partition is led by
node 2* on a completely healthy cluster — a gate failing because of its own
assumption. Recreate the topic each run and derive the victim.

Likewise "it rejoined" must be measured, not observed: the broker re-registers,
its replication lag is bounded, and its log-end offset has caught up to the
leader's. A static voter remains listed in the voter set the entire time it is
dead, so the voter list alone says nothing.

**Storage.** "The cluster works" is not evidence the storage tier is object
storage. Only listing objects in the bucket is.

## What RF=1 does and does not buy

Durability comes from the object store: a produce is acknowledged once the
record is there, so losing a broker loses no bytes, and that *is* provable —
pre-failure records are still readable after the leader dies.

Availability is a different claim. A partition whose leader dies is unwritable
until it is reassigned, and `__consumer_offsets` is RF=1 like everything else,
so a group's committed position lives on one broker too. Both windows are
measured and reported rather than asserted away. Anyone reading RF=1 as a
misconfiguration should be pointed at this paragraph.

## Idempotency is part of acceptance

Gates run on every converge, against a cluster that keeps its data. A gate
that counts absolute totals passes the first time and fails forever after —
against a perfectly healthy cluster. Recreate the gate's own topic (waiting out
Kafka's asynchronous deletion before reusing the name), or tag every record and
consumer group with a per-run value so each gate counts what this run produced.

The first converge is the one you watch, which is exactly why this defect
survives review.

## What this doctrine does not cover

Stated so nothing here reads as a stronger claim than the build supports:

- The consumer-group gate proves committed offsets survive the outage. It does
  **not** compute which `__consumer_offsets` partition holds the group and force
  the victim to be that partition's leader, so the RF=1 coordinator-loss case
  is exercised only when placement happens to line up.
- The certificate rollout serializes restarts by mutual exclusion (a lease),
  not by a fixed node order with per-generation acknowledgements. One at a time
  is the safety property; ordering is not.
- Transactional workloads are untested; see `pins.md`.

## Two failure modes that mimic success

- **Exit codes.** Every command in a converge can exit zero while the cluster
  is unusable. Ask the system what it has.
- **A gate that cannot fail.** If a gate would pass on a broken cluster, it is
  decoration. The clearest example here: a generic produce/consume round trip
  after killing a broker.
