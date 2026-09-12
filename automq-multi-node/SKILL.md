---
name: automq-multi-node
description: Diagnose multi-node AutoMQ deployments backed by object storage. Use for KRaft stuck in CandidateState or waiting for the high water mark, SCRAM-SHA-512 invalid credentials for every principal, missing KafkaServer JAAS entries, gates that pass only once, and bucket or SSH key ownership failures. Carries verified Vultr, AWS, Google Cloud and OCI context, including conditional-write, identity and VM allocation failures, listener and genesis contracts, and targeted failover acceptance gates.
---

# Multi-node AutoMQ

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
- GCS state discovery failing after the state bucket was created, or gcloud
  bucket preflight rejecting `not found: 404.`. See `references/gcloud.md`.
- GCS returns `ExcessHeaderValues`, or both competing conditional creates
  succeed. See `references/gcloud.md`.
- base apt installation stalls while the global Ubuntu security archive times
  out but the regional Google archive responds. See `references/gcloud.md`.
- OCI S3 compatibility rejects a competing create but accepts a stale
  `If-Match` replacement, or a newly created customer secret key returns
  `SignatureDoesNotMatch` for several minutes. See `references/oci.md`.
- OCI rejects valid-looking VM settings with `Valid ratio range: 0 - 0` or
  returns `500-InternalError, Out of host capacity.` despite positive service limits. See
  `references/oci.md`.
- OCI managed user creation returns `IdcsConversionError` with
  `The primary email must be specified.`, or a failed node create still
  blocks convergence after the shape changes. See `references/oci.md`.
- A failed OCI VM create leaves owned buckets and network resources, but
  delete returns `managed backend finalization refused; live or unowned
  state remains` or `compute cluster unavailable; refusing placeholder inventory`.
  See `references/oci.md`.
- OCI partial deletion returns `invalid SSH host inventory` before reaching
  storage or shared-resource cleanup. See `references/oci.md`.

- OCI storage cleanup fails after a successful multipart-list command
  returns empty stdout. See `references/oci.md`.

- Native OCI bucket update returns `404 NotFound` after the marker enters
  `deleting`; check the operation's HTTP method. See `references/oci.md`.

- An interrupted OCI finalization returns `compute state unavailable; legacy
  monolithic state requires explicit migration` despite a retired journal.
  See `references/oci.md`.

- OCI `GetObject` returns `SignatureDoesNotMatch` after a list or ops
  precondition gate passes. See `references/oci-2026-09-12.md`.
- OCI hosts report inactive UFW while raw INPUT rules reject every new
  Kafka connection. See `references/oci-2026-09-12.md`.

- OCI platform firewall rules disappear after reboot, or repeated applies
  append duplicate NTP rules. See `references/oci-2026-09-12.md`.
- Public acceptance cannot resolve a literal broker IP and skips TLS checks.
  See `references/oci-2026-09-12.md`.
- Adoption refuses an ops bucket containing failed readiness-probe objects.
  See `references/oci-2026-09-12.md`.

## What this stack is

AutoMQ speaks the Apache Kafka wire protocol but replaces replicated local
disks with object storage. A produce is acknowledged once the record is in the
bucket. Three nodes run both KRaft roles (`broker,controller`); the controller
quorum and inter-broker replication stay on a private network; the public
endpoint is `SASL_SSL` with SCRAM and an ACL authorizer.

The tested implementation is `github.com/getcolors/automq`. The original
Vultr deployment is `github.com/getcolors/automq-vultr`; the AWS lifecycle
assessment is `github.com/getcolors/automq-aws`. The Google Cloud deployment
is `github.com/getcolors/automq-gcloud`. OCI storage probes are in
`github.com/getcolors/automq-oci`. Claims come from those live
builds at the pins in `references/pins.md`, except where marked unverified.
Provider-specific observations retain their original scope. This skill carries
no copies of the implementation's files.

For Google Cloud provisioning, GCS signing and bucket lifecycle evidence, read
`references/gcloud.md`. Two complete live converges, data continuity, deletion and an independent
resource audit passed. For AWS lifecycle-owned buckets and
IP-address certificates, read `references/aws.md`. For OCI scoped storage probes, failed VM allocation and verified partial
deployment cleanup, read
`references/oci.md`. That September 11 account did not launch a broker.
The separate September 12 account passed three complete converges, including
two on one source pin and one after a firewall idempotency correction. Read
`references/oci-2026-09-12.md` for measured abrupt failover, reboot persistence
and continuity. The running cluster was retained, so its deletion is untested. The Vultr firewall and Cloudflare R2 observations below
are evidence for that deployment, not defaults for every provider.

## Replication factor 1 is the architecture

Every topic, internal ones included, is RF=1. That is upstream's shipped
default and it is not a misconfiguration: the bytes are in object storage
before the ack. Three nodes buy the controller quorum, partition failover and
throughput.

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
cluster that can never authenticate anyone and cannot be repaired in
place, because `kafka-configs --bootstrap-controller` answers
`UnsupportedEndpointTypeException`.

Derive "has this been initialized?" from a per-node format-complete record,
which is evidence that the work completed. A marker written before the work
cannot prove completion. The
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
  of nodes, which has nowhere to put a key id. A key created ninety seconds
  earlier is then reported as foreign. Emit an object: `{ ssh_key_id, nodes: [...] }`.
- **`~/.ssh/config`**: one managed block, marked with the profile, holds a
  stanza per node. An ownership check that derives the marker from the stanza
  it is searching for will read the block as somebody else's.

When porting a single-node package to N nodes, look for every place a name is
used for two purposes at once.

## Object storage belongs to exactly one cluster

AutoMQ supports **no configurable path prefix**. Keys are
`<hash>/_kafka_<clusterId>/<id>` at the bucket root. It therefore cannot be
confined to a prefix inside a shared bucket, and a bucket must belong to one
cluster outright.

The original Vultr deployment adopted external R2 buckets. For adoption, prove
emptiness by paginating the whole bucket, claim ownership with a conditional
create, and carry one transaction id across both buckets. A half-adopted pair
must resume; a mismatched pair must fail. Cloudflare R2 honours
`If-None-Match: *`; older boto3 versions reject the parameter before sending a
request. See failure-catalogue 8.

The AWS and Google Cloud deployments create state, data and ops buckets as lifecycle resources
beside the SSH keypair. Their delete paths remove application storage after
stopping the brokers and remove the state bucket last. Do not apply the
external-bucket adoption policy to lifecycle-owned storage. See
`references/aws.md` and `references/gcloud.md` for the verified ownership and
deletion boundaries.

The cluster id is also the object namespace, so it is desired state, not a
runtime accident: changing it orphans the data rather than renaming it.

## Certificates: one issuer, or a race you meet in ninety days

Every broker advertises its own name, so all of them must be in the
certificate. If each node issues its own, they race on the shared
`_acme-challenge` record for the bootstrap name and delete one another's
proof. Every node also holds a zone-editing DNS credential.

One node issues and publishes to the ops bucket; the others pull. Restarts are
ordered by a lease in object storage, **not** by each node's local quorum
check: a local check cannot order actors it cannot see, and these are combined
broker+controller nodes where a simultaneous restart destroys the majority.
The renewal path runs months later, when no Ansible control connection exists,
so distribution must not depend on one.

lego 5.x moved its flags under the subcommand; see failure-catalogue 7.

## Proving it works

`references/acceptance.md` has the doctrine. The two gates worth naming here:

- **Failover must be targeted.** Discover a partition whose leader is the
  broker you are about to kill and produce keyed records to exactly that
  partition. Unkeyed records over six partitions can pass without ever touching
  it. "Rejoined" is re-registration plus bounded lag plus a matching
  high-watermark. A static voter stays listed the whole time it is dead.
- **Gates must pass twice.** They run on every converge against a cluster that
  keeps its data, so one counting absolute totals passes the first time and
  fails forever after, against a healthy cluster. The first converge is the one
  you watch, which is why this survives review.

## References

- `references/failure-catalogue.md`. symptom-indexed, verbatim error text
- `references/contract.md`. listeners, JAAS, SCRAM at genesis, storage
- `references/pins.md`. the version set, how it was chosen, what is unverified
- `references/acceptance.md`. what each gate defends against

- `references/aws.md`, AWS lifecycle, private CA and verification scope
- `references/gcloud.md`, Google Cloud failure modes and verified acceptance and cleanup

- `references/oci.md`, OCI conditional-write failures and credential propagation

- `references/oci-2026-09-12.md`, A1 cluster acceptance, reboot persistence and bootstrap failures
