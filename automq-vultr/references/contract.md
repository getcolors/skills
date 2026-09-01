# The configuration contract, as the source defines it

What the broker actually requires for a three-node, fully authenticated,
S3-backed cluster — established by reading AutoMQ 1.7.4 (Kafka 3.9.1) and by
converging it, not from a quick start.

Settings are named here so you can check yours. The rendered file is the
companion package's (`github.com/getcolors/automq`); this is not a copy of it.

## Listener layout

Three listeners, and the split is a security boundary rather than a
convenience:

| Listener | Protocol | Bound to | Principal |
|---|---|---|---|
| `CONTROLLER` | `SASL_PLAINTEXT` + `PLAIN` | private address | a controller principal |
| `INTERNAL` | `SASL_PLAINTEXT` + `SCRAM-SHA-512` | private address | an inter-broker principal |
| `EXTERNAL` | `SASL_SSL` + `SCRAM-SHA-512` | `0.0.0.0` | client and admin principals |

Non-obvious requirements, each of which cost a converge:

- **`controller.listener.names=CONTROLLER` is mandatory** and is *not* implied
  by `listener.security.protocol.map`. Without it the broker does not start.
- **`CONTROLLER` must not appear in `advertised.listeners`.** Kafka rejects it.
- **Every SASL listener needs its own JAAS entry**, including the public SCRAM
  one — which carries no username or password, because a SCRAM server
  validates against the metadata log. Omitting it is failure-catalogue 5.
- `listener.name.controller.sasl.enabled.mechanisms` must be set explicitly;
  `sasl.mechanism.controller.protocol` alone does not imply it.
- Binding a listener to a **specific private address** means the container
  cannot use bridge networking — it cannot bind an address that belongs only to
  the host. Host networking is a requirement, not a preference.

## Why the controller listener uses PLAIN

SCRAM credentials live in the metadata log that the controller quorum must
form in order to serve. Using SCRAM there makes quorum formation depend on
something only a formed quorum can provide.

Genesis `--add-scram` records are the documented way out of that cycle, so
SCRAM on the controller listener is *arguable* — but it is not a safe
load-bearing assumption on this version (KAFKA-15513 reports exactly this
failure, and Kafka's own test harness still marks controller-quorum SCRAM
unsupported).

**PLAIN from a static JAAS file has no bootstrap dependency at all, which
makes it correct whether or not controller SCRAM works.** A design that is
right under both outcomes beats one that is right under a contested one. The
transport stays on the private network.

PLAIN carries **both directions in one entry**, because it has no credential
store behind it: `username`/`password` is who this node connects *as*, and
`user_<name>=` is who it accepts.

## SCRAM credentials at genesis

`--add-scram` with a **plaintext** password derives a *random salt per
invocation*. Formatting three voters that way writes three divergent bootstrap
records for one user.

Compute each principal's salt and salted password **once** and pass the
explicit form to every genesis format:

```
SCRAM-SHA-512=[name=…,salt=<b64>,saltedpassword=<b64>,iterations=<n>]
```

`saltedpassword` is `base64(PBKDF2-HMAC-SHA512(password, salt, iterations))`
with the digest's natural output length. This was verified byte-identical to
Kafka's own derivation; see failure-catalogue 3.

Replacement nodes are formatted **without** bootstrap records — KRaft
replicates SCRAM credentials in the metadata log and a replacement voter
catches up from the quorum.

**Drift can only be detected by authenticating.** `kafka-configs --describe`
exposes iterations and salt, never anything comparable to a plaintext.

## Authorization

`StandardAuthorizer` with `allow.everyone.if.no.acl.found=false`. The public
client principal is **not** a superuser: prefixed `Describe/Read/Write` on
topics and `Describe/Read` on groups, and nothing else — no `Create`, no
`Alter`, no `ClusterAction`, no `TransactionalId`.

Making `ANONYMOUS` a superuser to simplify the private listeners turns both of
them into unauthenticated cluster-root endpoints. Network isolation reduces
that exposure; it does not remove it.

## Storage

```
s3.data.buckets=0@s3://<data>?region=…&endpoint=…&pathStyle=true
s3.ops.buckets=1@s3://<ops>?region=…&endpoint=…&pathStyle=true
s3.wal.path=0@s3://<data>?…&batchInterval=<ms>&maxBytesInBatch=<bytes>
```

- Data and ops are addressed by **distinct bucket ids**; the WAL points at the
  **data** bucket.
- `pathStyle=true` for an account-level S3-compatible endpoint.
- `region=auto` works against Cloudflare R2.
- **`batchInterval` is the lever** when the object store is a different
  provider or region from the compute: every acknowledgement waits on an S3
  write, so it is latency traded for throughput.
- A bucket belongs to one cluster. See `pins.md` for why no prefix can confine
  AutoMQ inside a shared one.

## Replication factor

RF=1 for internal topics and as the default, which is upstream's own shipped
configuration. Durability is the object store. See `acceptance.md` for what
that does and does not buy.
