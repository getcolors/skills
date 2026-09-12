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

## AWS assessment, 2026-09-10

The same AutoMQ image digest passed two live converges on AWS Ubuntu 24.04
`t3.large` nodes in `us-east-1a`, with lifecycle-owned S3 buckets and IP SAN
certificates signed by a deployment CA. The verified source was AutoMQ
`e3beeaf08472fc3ab4e5121eca876e1f0bb6f8e9`, published by launcher commit
`debb50b`, with colors-compute
`87ec5661fc8807159419d90d437247f3503469c7`.

See `aws.md` for the measured gates, deletion evidence and limits. Later
launcher refreshes do not silently extend the original run's claims. The
Vultr-specific OS and provider rows above remain the original 2026-09-01 pins.

## Google Cloud assessment, 2026-09-11

Two complete live converges, continuity, full deletion, repeated deletion and
an independent final resource audit passed. The assessment used project
`colors-508307`, three `e2-standard-2` machines in `us-central1-a`, and pinned
image `projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-amd64-v20260906`.
It retained the AutoMQ 1.7.4 digest above.

Published colors-compute commit `d2c75d7` supplies the native GCS state backend
and managed lifecycle in all three colors. The integrated GCS signer and
package path were AutoMQ source `f0c34f1`, with launcher publication `f6877e0`.
The live runs used Green. The second fetched published pins with no development
`LIB_ROOT` overrides and preserved a separate 50-record continuity topic.

See `gcloud.md` for evidence links, observed failure modes and limits. On a
botocore or GCS signer change, rerun the positive and negative conditional-write
probes. HTTP 200 without competitor refusal does not prove ownership safety.

The published deployment and evidence are pinned at
[automq-gcloud c5184d352fbb6467e179137f32ef6913368e8bc0](https://github.com/getcolors/automq-gcloud/commit/c5184d352fbb6467e179137f32ef6913368e8bc0).

## OCI assessment, 2026-09-11

The OCI assessment used profile `automq-oci` in `eu-frankfurt-1` with only OCI
state, data and ops buckets. It retained the AutoMQ 1.7.4 image digest above,
but never launched a broker. Shape validation and capacity failures prevented
VM allocation. No OCI Kafka acceptance or repeated cluster convergence is
claimed.

The attempted ARM image was
`Canonical-Ubuntu-24.04-aarch64-2026.08.25-0`,
`ocid1.image.oc1.eu-frankfurt-1.aaaaaaaatnudwzlqzctpx5rrxohiionypan5fngceqdbybtw6ve7oyhmnnqq`.
The compute stage used `oracle/oci` 8.4.0. The storage stage pinned
`oracle/oci` 7.32.0 and `hashicorp/tls` 4.1.0.
The operator CLI was OCI 3.90.2 with Python SDK 2.165.1.

The scoped storage probe ran the actual package storage step with development
source overrides and the service-user email correction before its publication
in AutoMQ `ec23c98b91ff7a8238fcf9ff039d00f061b0dccf`. The native conditional-write
and lease implementation was unchanged from source
`71b6032bd7576531149910d65ca64c811bf106fb`. Do not describe that probe as a
complete deployment using only published dependencies.

The final published package is AutoMQ
`d37766dbac4f115f543fa55cdbd3f25d46a4fc32`; its launchers load source
`ace2f656236741df3d92a6319599e27fd7dbd11f` with colors-compute
`58ac766d17cc1b174992986c1088d9d7045e13b5`. Publishing those pins does not
retroactively establish cluster acceptance. `oci.md` records the observed
storage, provisioning and partial-deletion behavior.

On an OCI SDK, provider or signing change, repeat both allowed and refused
conditional creates and replacements, verify the final object value, and
exercise lease renewal, expiry takeover and stale release. Repeat application
state-denial probes against an operator-proven existing bucket and object.
For lifecycle changes, test partial deletion and interrupted finalization,
including native version pagination and the final independent resource audit.

The [deployment and evidence](https://github.com/getcolors/automq-oci/commit/19b1a9e15f1d95bc3db7fe24840015c0e9718251) are pinned at
`19b1a9e15f1d95bc3db7fe24840015c0e9718251`. Published-pin build, create dry-run
and repeated deletion exited 0 without development overrides. The final native
audits confirmed owned-resource absence and preservation of the borrowed
network. These checks establish partial-deployment cleanup, not OCI Kafka
acceptance.

## OCI A1 assessment, 2026-09-12

A different OCI account, namespace `fryovegrk8e7`, ran three
`VM.Standard.A1.Flex` broker/controllers with 1 OCPU and 8 GiB each across
Frankfurt's three availability domains. It retained the AutoMQ 1.7.4 image
index above and Ubuntu `Canonical-Ubuntu-24.04-aarch64-2026.08.25-0`.

Two complete converges passed on AutoMQ source
`5aac5a3dfc689071156f5e67c5f1bb7eaec5ca50`, published by launcher commit
`c3492fd3627091ad3c07a321061689454534fced`. A final complete converge passed
after the firewall idempotency correction on source
`6b76c01e730c79cfef3e0f9baee68f85b29bd604`, published by
`379608efb87f53a67e5d556c42efd4a660a531c3`. Both used colors-compute
`58ac766d17cc1b174992986c1088d9d7045e13b5`. These successful full runs used
published dependencies without local source overrides. Intermediate diagnosis
and repair used development code and exact-object or exact-rule cleanup as
recorded in the report.

Each full run passed nine host and 16 public gates. The final source therefore
has one complete pass, alongside two complete passes on the preceding source;
do not report two passes on the final pin. Separate firewall calls verified
idempotency of the final helper on all three hosts. A repaired real reboot
preserved platform and owned rules, and an independent continuity topic
survived the reboots and repeated converges.

The [deployment and dated evidence](https://github.com/getcolors/automq-oci/commit/ee2789daa1738b33563488b9294940179234ea09)
are pinned at `ee2789daa1738b33563488b9294940179234ea09`. Read
`oci-2026-09-12.md` for exact observations and fault timing. The cluster was
retained with its destruction guard enabled. No running-cluster deletion,
disk-loss, AZ-loss, transactional-workload or sustained-capacity claim follows
from this assessment. The September 11 account's cleanup remains historical.

Package documentation publication `3da40c6281ae4eba3ab21a80ae9c21c3ebed8cb3`
links this evidence; its launchers still use source `6b76c01`.
