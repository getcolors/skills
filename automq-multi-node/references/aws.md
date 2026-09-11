# AWS lifecycle and verification scope

The live assessment on 2026-09-10 used profile `automq-aws`, three Ubuntu 24.04
`t3.large` nodes in `us-east-1a`, and the AutoMQ 1.7.4 digest in `pins.md`.
Its evidence is [the deployment verification report](https://github.com/getcolors/automq-aws/blob/main/verification.md).
All AWS resources were deleted after the assessment.

## Buckets have a deployment lifecycle

The deployment created a state bucket, separate data and ops buckets, and an
application IAM identity restricted to those two application buckets. The
actual application credentials could list both app buckets but received HTTP
403 on the state bucket's `HeadBucket` request.

Deletion stopped all three brokers before removing application storage and its
IAM identity. Compute and the owned SSH keypair followed. Backend finalization
removed the state bucket and its versioned objects last. A repeated delete
passed with no backend and without SSH access. The default destruction guard
refused deletion before destructive stages.

These were owned resources, not external buckets adopted by the original R2
configuration. Bucket ownership must determine cleanup behavior. The final
provider audit found no owned VPC resources, machines, root volumes, keypair,
application IAM identity or buckets. Local owned SSH key files and aliases were
also absent.

## IP certificates require explicit client trust

This assessment used a deployment CA and public IP SANs, with no DNS provider.
Every external TLS gate verified both the exported CA and the IP identity.
Clients passed the exported CA to kcat through `ssl.ca.location`. The CA private
key remained on the issuer node.

This configuration does not establish the Cloudflare DNS-01 renewal claim.
The original single-issuer and serialized-restart requirements still apply to
certificate distribution on combined broker/controller nodes.

## CLI memory can kill an otherwise healthy broker

Kafka CLI and healthcheck processes inherited the broker's 2 GiB minimum heap.
The live run observed an OOM kill. The package fixed those processes at a
256 MiB maximum heap and updated existing brokers one at a time with readiness
checks. Both full successful runs completed without another observed OOM kill.
Check the CLI environment as well as the broker heap when a gate coincides with
an OOM event.

## What the live gates proved

Two complete converges passed, the second with immutable published dependencies
and all development overrides unset. On-host checks verified a 500-record exact
match. External checks passed all 16 gates, including a 200-record public round
trip, access refusals, a targeted outage, and a controller restart. A separate
50-record topic remained an exact match across the second converge.

Node 2 led the tested partition. All 100 acknowledged pre-outage records
survived its controlled container stop. The partition accepted writes one second
after `docker stop` returned. The restarted broker registered with zero lag and
matching log end offsets. Checked consumer-group offsets survived.

The one-second observation starts after the stop command returns. It is not a
crash-recovery guarantee. The test did not force the consumer coordinator onto
the victim, destroy a disk, lose an AZ, or test transactions. A short 20,000-record
burst reported 1,530.57 records/s and 11,042 ms p99. It is not a steady-state
capacity benchmark.
