---
name: automq-vultr
description: Everything a multi-node AutoMQ cluster needs that the docs and the single-node quick start will not tell you - two firewalls in front of every Vultr node (the provider group AND the ufw the image ships enabled, which passes ICMP while dropping inter-node TCP, so ping says the network is fine and the KRaft quorum never elects), SCRAM records that must be bootstrapped at genesis or the cluster can never authenticate anyone, and gates that prove a failover instead of assuming it. Use whenever AutoMQ, a Kafka cluster backed by object storage, KRaft on Vultr, or replication factor 1 comes up. Also on these symptoms - "waiting for the controller to acknowledge that we are caught up", endless "we still don't know the high water mark", perpetual CandidateState with a climbing epoch, "Could not find a 'KafkaServer' or 'external.KafkaServer' entry", "invalid credentials with SASL mechanism SCRAM-SHA-512" from every principal, "error creating VPC 2.0". Full symptom index in the body.
---

# Multi-node AutoMQ on Vultr

## Symptom index

Each has a full entry, with verbatim text, in
`references/failure-catalogue.md`:

- `error creating VPC 2.0: {"error":"Not found.","status":404}`
- `Port numbers must be between 1 and 65535` for a port you did configure
- `invalid credentials with SASL mechanism SCRAM-SHA-512` from **every**
  principal, including ones you never changed
- `Received a fatal error while waiting for the controller to acknowledge that
  we are caught up`
- endless `the loader is still catching up because we still don't know the high
  water mark yet`
- every node a perpetual `CandidateState` with the epoch climbing, no votes
- `Could not find a 'KafkaServer' or 'external.KafkaServer' entry in the JAAS
  configuration`
- `java.nio.file.NoSuchFileException` naming a file you can `cat`
- `Incorrect Usage: flag provided but not defined: -accept-tos`
- `Unknown parameter in input: "IfNoneMatch"`
- `Syntax error in template: unexpected char '…'`
- the deployment refusing to converge because of an ssh block it wrote itself
- an ssh key reported as "not in this deployment's state" ninety seconds after
  this deployment created it
- a gate that passed on the first converge and fails on every one after

## What this stack is

AutoMQ speaks the Apache Kafka wire protocol but replaces replicated local
disks with object storage. A produce is acknowledged once the record is in the
bucket. Three nodes run both KRaft roles (`broker,controller`); the controller
quorum and inter-broker replication stay on a private network; the public
endpoint is `SASL_SSL` with SCRAM and an ACL authorizer.

The tested implementation is `github.com/getcolors/automq`, with
`github.com/getcolors/automq-vultr` as its deployment. This skill carries no
copies of their files — it explains what the errors mean and why the
configuration is what it is.

## Replication factor 1 is the architecture

Every topic, internal ones included, is RF=1. That is upstream's shipped
default and it is not a misconfiguration: the bytes are in object storage
before the ack. Three nodes buy the controller quorum, partition failover and
throughput — not copies.

Two things follow, and both are load-bearing:

- **Durability is provable**: records written before a broker dies are still
  readable afterwards.
- **Availability is a separate claim**: a partition whose leader dies is
  unwritable until reassignment, and `__consumer_offsets` is RF=1 too, so a
  consumer group's committed position lives on one broker. Measure both windows
  instead of asserting them away.

Anyone who "fixes" RF to 3 adds cost and write amplification and removes
nothing from the risk column.

## The three discoveries the docs will not give you

### 1. Two firewalls, and ping cannot see the one that matters

A Vultr node sits behind the **provider's firewall group** *and* **ufw, which
the Ubuntu image ships enabled** with a single `22/tcp` rule:

```
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)
22/tcp                     ALLOW IN    Anywhere
```

ufw passes ICMP. So every node pings every other node, the private network
looks perfect, and every inter-node TCP connection is dropped. The KRaft quorum
never elects; the broker half dies sixty seconds later blaming *itself*; and
nothing in Kafka's output mentions a firewall. The same rule would have
silently blocked the public Kafka port.

**Test raw TCP, never ping.** Stand up a listener on a peer and connect to it.
Then check `ufw status` on the host *before* the provider's console.

### 2. A marker is not evidence

The failure that cost the most: a converge claimed a "genesis" marker and then
failed during the format. Every later run read "already initialized" and
formatted its nodes **without** SCRAM bootstrap records. The result is a
cluster that can never authenticate anyone — and that cannot be repaired in
place, because `kafka-configs --bootstrap-controller` answers
`UnsupportedEndpointTypeException`.

Derive "has this been initialized?" from **evidence that the work completed** —
a per-node format-complete record — never from a marker written before it. The
same principle makes the per-node record two-phase (`intent`, then `complete`):
without the split, a converge killed mid-format is indistinguishable from disk
loss on the next run, and those demand opposite responses.

### 3. Determinism dies of small randomness

`--add-scram` with a plaintext password salts randomly *per invocation*, so
formatting three voters that way writes three divergent records for one user.
Compute each principal's salt and salted password once and pass the explicit
`salt=…,saltedpassword=…` form to every node. See `references/contract.md`.

## Single-node assumptions that hide in shared machinery

Two independent bugs, one shape: with one machine, two different names are the
same string, so nothing distinguishes them.

- **Compute output**: ownership of the generated ssh key is read from
  `params.ssh_key_id`. A multi-node stack naturally emits `params` as a *list*
  of nodes, which has nowhere to put a key id — so a key created ninety seconds
  earlier is reported as foreign. Emit an object: `{ ssh_key_id, nodes: [...] }`.
- **`~/.ssh/config`**: one managed block, marked with the profile, holds a
  stanza per node. An ownership check that derives the marker from the stanza
  it is searching for will read the block as somebody else's.

When porting a single-node package to N nodes, look for every place a name is
used for two purposes at once.

## Object storage belongs to exactly one cluster

AutoMQ supports **no configurable path prefix** — keys are
`<hash>/_kafka_<clusterId>/<id>` at the bucket root. It therefore cannot be
confined to a prefix inside a shared bucket, and a bucket must belong to one
cluster outright.

Adopt rather than create: prove emptiness by paginating the *whole* bucket (a
prefix check misses exactly the hash-prefixed keys that matter), claim
ownership with a conditional create, and carry one transaction id across both
buckets so a half-adopted pair resumes and a mismatched one fails. Cloudflare
R2 honours `If-None-Match: *`; the distribution's boto3 may not know the
parameter, which is a client limitation, not a protocol one — see
failure-catalogue 8.

The cluster id is also the object namespace, so it is desired state, not a
runtime accident: changing it orphans the data rather than renaming it.

## Certificates: one issuer, or a race you meet in ninety days

Every broker advertises its own name, so all of them must be in the
certificate. If each node issues its own, they race on the shared
`_acme-challenge` record for the bootstrap name — each deleting the others'
proof — and every node ends up holding a zone-editing DNS credential.

One node issues and publishes to the ops bucket; the others pull. Restarts are
ordered by a lease in object storage, **not** by each node's local quorum
check: a local check cannot order actors it cannot see, and these are combined
broker+controller nodes where a simultaneous restart destroys the majority.
The renewal path runs months later, when no Ansible control connection exists —
so distribution must not depend on one.

lego 5.x moved its flags under the subcommand; see failure-catalogue 7.

## Proving it works

`references/acceptance.md` has the doctrine. The two gates worth naming here:

- **Failover must be targeted.** Discover a partition whose leader is the
  broker you are about to kill and produce keyed records to exactly that
  partition. Unkeyed records over six partitions can pass without ever touching
  it. "Rejoined" is re-registration plus bounded lag plus a matching
  high-watermark — a static voter stays listed the whole time it is dead.
- **Gates must pass twice.** They run on every converge against a cluster that
  keeps its data, so one counting absolute totals passes the first time and
  fails forever after, against a healthy cluster. The first converge is the one
  you watch, which is why this survives review.

## References

- `references/failure-catalogue.md` — symptom-indexed, verbatim error text
- `references/contract.md` — listeners, JAAS, SCRAM at genesis, storage
- `references/pins.md` — the version set, how it was chosen, what is unverified
- `references/acceptance.md` — what each gate defends against
