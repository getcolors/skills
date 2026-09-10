---
name: neon-multi-node
description: Use when self-hosted Neon says "server does not support SSL, but SSL was required", compute_ctl logs "unknown TLS key type", a safekeeper outage rehearsal fails with "FAIL AssertionError", psql returns "INSERT 0 1" instead of the expected value, a timed-out quorum write appears after recovery, cleanup reports Ansible ENOENT, repeat delete reports migration after removing its backend, or three safekeepers and S3 are being mistaken for complete HA. Verified AWS multi-node TLS, SQL witness, WAL quorum, S3 recovery and lifecycle contracts.
---

# Neon Multi-Node

## Route by symptom

| Symptom or situation | Read |
|---|---|
| SSL required but server has SSL off | [TLS feature gate](references/failure-catalogue.md#ssl-required-but-disabled) |
| `unknown TLS key type`, connection closes after enabling experimental TLS | [Certificate parser](references/failure-catalogue.md#unknown-tls-key-type) |
| Outage write returns `FAIL AssertionError` despite an inserted row | [psql command tags](references/failure-catalogue.md#assertion-after-an-acknowledged-insert) |
| Timed-out no-quorum write exists after quorum returns | [Uncertain transaction outcome](references/failure-catalogue.md#timed-out-write-present-after-recovery) |
| Three safekeepers or S3 presented as complete HA or zero RPO | [Acceptance boundaries](references/acceptance.md) |
| Installed Ansible reports ENOENT during deletion | [Scaffold event](references/failure-catalogue.md#ansible-exists-but-cleanup-reports-enoent) |
| Repeat delete reports migration after backend retirement | [Missing bucket vs missing key](references/failure-catalogue.md#repeat-delete-reports-migration-after-complete-cleanup) |
| Resource template cannot be found, or ingress validation fails offline | [Build traps](references/failure-catalogue.md#offline-build-traps) |

## Provenance and ownership

This knowledge comes from the September 10, 2026 live AWS deployment of
[getcolors/neon-multi-node](https://github.com/getcolors/neon-multi-node), with
[evidence in neon-multi-node-aws](https://github.com/getcolors/neon-multi-node-aws/tree/main/evidence).
Claims below were verified against that deployment unless labeled source review,
offline validation, or unverified. The exact [pins](references/pins.md) delimit
what was tested. This skill carries reasoning; the companion package owns all
working files. Do not reconstruct its scripts from this prose.

The verified shape is five Ubuntu machines in one AWS availability zone:
compute-0, pageserver-0 with the broker, and safekeeper-0/1/2. Six containers
run on those machines. Three independent safekeeper disks provide a WAL quorum;
the one compute and one pageserver remain service failure points. Native
PostgreSQL TLS is reached through a DNS-only Cloudflare record and a restricted
client CIDR. Managed S3 backend and application buckets are separate resources.

## Diagnose the boundary that actually failed

A valid TLS field in a compute specification did not enable TLS at the pinned
release. Reading `compute.rs::tls_config` showed the experimental feature gate.
Enabling it exposed a second, independent issue: `tls.rs::verify_key_cert`
rejected the actual ACME certificate's ECDSA/SHA384 signature algorithm.
The accepted deployment uses native PostgreSQL SSL settings and its mounted
certificate/key, bypassing that helper. See the [source contract](references/contracts.md)
before treating the feature flag as a fix.

A successful SQL operation and a successful harness assertion are different
facts. The first safekeeper rehearsal acknowledged its INSERT, then asserted
on psql's trailing command tag. The row existed, but its witness ledger did not.
Quiet psql output fixed the harness; a new complete rehearsal supplied the
recovery proof. That failed attempt must not be relabeled a passed gate.

A client timeout likewise does not establish rollback. With two safekeepers
stopped, the write was not acknowledged within the bounded client wait. After
quorum returned, the uncertain row was present. Applications need a way to
reconcile that outcome; an automatic retry must not assume the first attempt
never happened.

## Hold success to these gates

Use the companion's implementation and [acceptance doctrine](references/acceptance.md):
external hostname verification, authentication and plaintext negatives, exact
persistent witnesses, per-member outage witnesses, observable S3 uploads,
scoped-storage denial checks, and recovery readback. Container liveness and an
arbitrary S3 object are supporting observations, not substitutes.

The verified recovery preserved the original random external witness and six
unique acknowledged outage witnesses through compute recreation, individual
safekeeper outages, quorum interruption, broker restart, and pageserver tenant
cache removal followed by reattachment, and empty local-state reconstruction
of one safekeeper through the other two. Safekeeper WAL survived the pageserver
recovery. This does not prove recovery after simultaneous loss of every storage
disk, automatic compute/pageserver failover, multi-zone availability, or a
numerical full-storage-loss RPO.

Deletion is a separate acceptance boundary. The package's guarded workflow
requires current-run proof that every writer stopped before application S3
purge, then completes compute and backend retirement. Treat final cloud absence
as an independent check; complete cleanup and repeated deletion passed, with
zero remaining deployment resources independently observed. Details are in
[acceptance](references/acceptance.md).
