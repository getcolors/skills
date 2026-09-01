# Pinned versions and the rules that generated them

Verified together by a real converge on 2026-09-01. A change to any line here
invalidates the claims that depend on it; see §Retest conditions.

## The stack

| Component | Pin | Why this one |
|---|---|---|
| AutoMQ | `automqinc/automq:1.7.4@sha256:68bf5df674ab9755da51f5200c152df391b0968aeeaf9ec4d12619517cd1234f` | Released 2026-08-29, current at build time. Built on Apache Kafka **3.9.1** — the wire protocol clients speak. |
| Host OS | Vultr `os_id` 2284, Ubuntu 24.04 LTS x64 | The image's shipped `ufw` state is load-bearing; see failure catalogue 4. |
| lego | 5.4.0 | 5.x moved its flags under the subcommand; catalogue 7. |
| boto3 | Ubuntu's `python3-boto3` | Distribution package, not pip: 24.04 enforces PEP 668. Predates `IfNoneMatch`; catalogue 8. |
| Terraform provider | `vultr/vultr ~> 2.0` | Still ships `vultr_vpc2`, whose API is gone; catalogue 1. |

**The image must be pinned by digest.** This package owns its configuration
templates rather than running an upstream installer, so nothing tells it when a
floating tag moves underneath it. A digest turns a silent retag into a failure
at pull time instead of a behaviour change at run time.

## Rules that generated the version set

1. **Pin the release, then read the source at that tag.** Upstream's
   `docker/docker-compose.yaml` at `1.7.4` is a single-node MinIO quick start —
   `node.id=0`, a hard-coded cluster id, PLAINTEXT everywhere. Nothing in it
   survives contact with three nodes, TLS, or authentication. It is still the
   right thing to read, because it is the only place the S3 wiring is spelled
   out. `config/kraft/server.properties` at the same tag is where the defaults
   live.
2. **Move the storage and compute versions together or not at all.** AutoMQ
   ships one image carrying both.
3. **Verify endpoints, not clients.** A resource that compiles proves nothing
   about whether the provider still serves it.

## Facts about 1.7.4 worth carrying forward

- Object keys are `<hash>/<namespace>/<objectId>` where the namespace is
  `_kafka_<clusterId>` (`Constants.DEFAULT_NAMESPACE` = `_kafka_`), built by
  `s3stream/.../metadata/ObjectUtils.genKey`. The leading component is a hash of
  the object or node id.
- **`BucketURI` supports no path prefix.** Read
  `s3stream/.../operator/BucketURI.java`: the only keys are `endpoint`,
  `region`, `accessKey`, `secretKey`, `apiCallTimeoutMs`,
  `apiCallAttemptTimeoutMs`, plus extensions read by name (`pathStyle`).
  Consequence: **a bucket belongs to exactly one cluster.** AutoMQ cannot be
  confined to a prefix inside a shared bucket.
- No production code lists a bucket root — every list is scoped to a hash
  prefix. (Grepped for root listings; the hits are all tests.)
- Upstream defaults ship `offsets.topic.replication.factor=1` and
  `transaction.state.log.replication.factor=1`, plus
  `elasticstream.enable=true` and the AutoBalancer metrics reporter.
- The S3 wiring is three settings: `s3.data.buckets` (bucket id 0),
  `s3.ops.buckets` (id 1), and `s3.wal.path` pointing at the **data** bucket.

## Retest conditions

Re-verify these when the pin moves:

- **AutoMQ image** — re-read `config/kraft/server.properties` and
  `docker/docker-compose.yaml` *at the new tag*. Re-check that `BucketURI` still
  supports no prefix before assuming a bucket can be shared.
- **Host image** — re-check `ufw status` on a fresh instance. If a future image
  ships ufw disabled, the host-firewall tasks become no-ops rather than
  load-bearing, and the quorum failure in catalogue 4 changes shape.
- **Vultr provider** — if `vultr_vpc2` is finally removed, catalogue 1 becomes
  a compile error instead of a runtime 404, which is an improvement.
- **botocore** — once the distribution ships a version with `IfNoneMatch`, the
  event-hook workaround in catalogue 8 can become the plain parameter. The hook
  keeps working either way.

## Unverified

Stated so nothing here is mistaken for tested:

- **Transactional workloads.** `__transaction_state` is RF=1 like every other
  internal topic. Its behaviour across a broker outage was neither tested nor
  claimed.
- **Sustained throughput and p99 under load.** The build measures produce
  latency once and reports it; that is a data point, not a benchmark.
- **Certificate renewal on the timer.** The issuance path was exercised; the
  90-day renewal path and its object-store distribution were not observed
  completing on a timer.
- **Recovery from real disk loss.** The refusal-to-reformat guard was reasoned
  through and its records exist, but no node's disk was actually destroyed.
