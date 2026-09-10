# AWS standalone deployment: evidence and review findings

## Evidence boundary — September 10, 2026 completed lifecycle

The standalone `getcolors/clickhouse` package was exercised by
[`getcolors/clickhouse-aws`](https://github.com/getcolors/clickhouse-aws), profile
`clickhouse-aws`. This is distinct from the September 3 Vultr Langfuse tier.
The first live create provisioned four machines in 233 seconds and completed
Metabase configuration in 157 seconds, then failed to parse the ClickHouse
playbook before ClickHouse startup. Create 2 completed ClickHouse configuration in 180 seconds, then hung during
dbt client initialization. The WireGuard MTU fix below passed a focused live
client probe. The old blocked dbt process was intentionally terminated (143);
the next full published-pin create passed application acceptance and rehearsal
but failed its final storage drift gate. Corrected published-pin create 4
subsequently passed with exit 0, as recorded below. The focused runtime
rehearsal, separate continuity checks, full deletion and repeated deletion
passed as recorded below. The temporary deployment no longer exists.

The deployment's `evidence/rendered-yaml-failure.txt` records the actual parser
failure. `evidence/resources-created.json` independently verifies four running
instances, their encrypted 60 GiB roots, one VPC/keypair, private encrypted S3
buckets, versioned state, and five DNS-only records. The initial
`evidence/initial-baseline-summary.json` preserves the initial zero-resource
observation; `evidence/resource-baseline.json` was later updated with live
resource IDs for the teardown audit.

The implementation remains in the package: `green/src/resources/io/github/getcolors/clickhouse/tools/`
contains the `storage/main.tf` stage and `ansible/clickhouse-backup.*`,
`clickhouse-rehearsal.yml`, and `clickhouse-monitor.py`; equivalent Red/Blue
resources are generated and checked there. The deployment owns independent
`check_storage.py` and `evidence/check_resources.py` evidence probes. This
Context Skill carries no copies.

## AWS private peers are inventory data

Review found that the Hetzner ancestor rendered literal `10.20.1.11`, `.12`,
and `.13` into `remote_servers`, Keeper clients and raft voters, and allowed
admin access from `10.20.0.0/16`. AWS assigns private addresses dynamically;
the deployed VPC is `10.78.0.0/16`. Resolve every peer from the joined compute
inventory and render admin network allowances accordingly. The mismatch was
caught before ClickHouse startup; it was **not** an observed AWS quorum outage.

AWS security groups enforce role-specific private sources: Keeper and raft
admit ClickHouse peers, while Metabase gets HTTP/native access. The acceptance
probe must first reach HTTP from Metabase over the private network and then
fail to reach Keeper 9181. A public-port refusal alone says nothing about
private role isolation. WireGuard provides the client access path; Cloudflare
DNS-only A records point at stable VPN addresses, not EC2 public addresses.
The zone is `bigconfig.online`, independently of the hostname suffix
`clickhouse-aws.bigconfig.online`; querying the suffix as a zone is incorrect.

## Small queries pass, dbt hangs: WireGuard MTU from a jumbo interface

Observed during create 2: a tiny urllib `SELECT version()` as the dbt user
passed, while `clickhouse_connect.get_client()` failed with `ReadTimeoutError`
and then `StreamFailureError('Stream failed during read (connection closed by server)')`
during `SELECT name,value,readonly FROM system.settings LIMIT 10000`.
This size-dependent behavior survived valid authentication and healthy
ClickHouse quorum. The live local WireGuard MTU was 8920, and all four server
interfaces were 8921. A 1372-byte ping payload passed; 2000 bytes were lost.
After setting every owned WireGuard interface to 1420, the same client
initialized and answered `SELECT 1` in under one second.

The automatic value comes from `wg-quick`'s `set_mtu_up` function, which derives
MTU from the endpoint route/interface and subtracts tunnel overhead; it is
not an end-to-end path measurement. AWS's internet gateway path supports an
MTU of 1500 even when EC2 interfaces support jumbo frames. This source/doc
explanation is consistent with the measured large-packet failure and the
controlled MTU correction. See [WireGuard source](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash#n126)
and [AWS network MTU guidance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/network_mtu.html).

The package now renders explicit `MTU = 1420` in both local and server
WireGuard `[Interface]` sections in all three implementations. Changing only
the operator side leaves the server's large replies exposed to the same
path limit. The focused measurements are recorded in the deployment's
`evidence/wireguard-mtu-fix.json`; the subsecond client result was observed
by the operator in the same correction. Focused dbt/acceptance and runtime rehearsal subsequently passed; complete
published-pin create 4 subsequently passed. This is a tested setting for this public EC2 tunnel path, not a
universal MTU for every private WireGuard topology.

## Managed S3 has two separate lifecycle owners

`colors-compute` owns bootstrap and finalization of the state bucket through
`s3-bucket-mode=managed`. Its bootstrap precedes the first state read. The
package's Terraform storage stage owns the backup bucket and its scoped IAM
identity. Both are resources of this deployment, as is the managed SSH key;
pre-existing unowned buckets are refused rather than silently adopted.

The managed backend uses the standard AWS credential chain. Sibling operator
files map `COLORS_PAR_AWS_ACCESS_KEY_ID` and
`COLORS_PAR_AWS_SECRET_ACCESS_KEY` to `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`. Scoped backup credentials cross into Ansible only
through the environment and stay in host files with mode 0600. They must be
able to list the backup bucket and receive an actual access denial when
listing the state bucket. Terraform's sensitive output is captured in memory;
it is not public deployment evidence.

Review caught two teardown gaps: a running backup timer could race bucket
removal, and a retired-compute short circuit skipped the remaining backend
finalizer. Stop the timer and active backup service before destroying storage.
Keep the backend until DNS/storage/compute state is empty, and route a retry
with retired compute to backend finalization. A prior compute retirement is
not proof that the application's whole deletion completed. These gaps were found in review rather than encountered as live teardown
failures; the corrected full and repeated deletion paths subsequently passed.

## The backed-up database must contain the workload

The standalone dbt workload lives in `analytics`; the Langfuse ancestor's
`BACKUP DATABASE default` alone would omit it. The AWS implementation includes
`analytics` and `default` in its native set, then restores `analytics` into
`restore_check`. Required evidence is the actual `events_summary` content,
plus zero overlapping Keeper paths with live `analytics`, rather than an
empty scratch database's existence. Runtime proof passed in rehearsal 3,
including exact restored model contents and zero Keeper collisions.

Review also caught two misleading acceptance shapes. An outage drill using
fixed ID 2 and `INSERT ... WHERE NOT EXISTS` writes nothing on its second
run; use a fresh run ID and verify it on a surviving replica and the recovered
one. A rehearsal table in `default` adds three rows to the global
`system.replicas` count; scope the existing six-replica analytics gate to its
workload instead of assuming no other replicated table exists. The original
fixed global count would fail a valid repeat converge. Both were found in
review before that repeat-converge failure was observed.

## Completed runtime and lifecycle evidence

`evidence/live-rehearsal-3.txt` passed the full focused rehearsal. Its completed
native backup contained 53 logical files/5313 logical bytes, 35 physical payload
entries plus `.backup` (36 S3 objects), 13895 physical bytes, and 9356 metadata
bytes. Restore reproduced `events_summary`: purchase count 2 and sum
69.80000114440918; signup count 2 and sum 2. Zero Keeper paths collided.
A fresh write made during the second replica's outage appeared on the third;
the second replica restarted, read the new row, and drained its queue to zero.
Metabase reached private HTTP and was denied Keeper. All three monitors passed.

`evidence/storage-isolation-1.json` independently verified the native metadata
mapping, marker and manifest, encrypted/private buckets, versioned state,
backup-bucket read access and state-bucket HTTP 403 denial using scoped keys.
These are measured passes, not inferred from installed scripts.

Published-pin create 3 passed application acceptance and rehearsal; separate
continuity, health and storage audits passed. Its final storage drift gate
returned exit 2. Corrected published-pin create 4 then passed with exit 0,
including application acceptance, rehearsal and final no-change drift
(`evidence/live-create-4.txt`). Full and repeated deletion subsequently passed, with independent
recorded-resource absence checks described below. Installed timers and
exit-zero provisioning alone would not discharge those gates. Node-0 failure,
AZ failure and Keeper-total-loss recovery are outside this assessment unless
separately exercised.

## Logical backup files are not physical S3 objects

The live backup of `analytics` and `default` returned `BACKUP_CREATED` on
26.3.29.7, but the inherited direct equality gate failed: 30 S3 objects versus
33 `num_files`, and 9107 S3 bytes versus 3875 `total_size`. Native `.backup`
metadata captured by the operator (`/tmp/clickhouse-aws-backup-metadata.xml`)
explained every difference: 33 logical file entries/3875 bytes, four aliases
using `data_file` references to two existing payload files, 29 unique payload
objects/3853 bytes, and `.backup` itself at 5254 bytes. The physical listing
therefore totals 30 objects/9107 bytes. `system.backups` reported matching
physical fields: `num_entries=29`, `compressed_size=9107`,
`uncompressed_size=9107`.

This directly corrects this skill's prior blanket bucket-to-logical-counter
rule, even without a version bump. The September 3 Vultr equality statement
is historical evidence under review and cannot authorize the old gate.
Check logical metadata against `num_files`/`total_size`; resolve nonempty
entries through `data_file` aliases and compare the complete deduplicated
path/size map, plus `.backup`, to S3. The physical counter check for this full
uncompressed set is `num_entries + 1` objects and `compressed_size` bytes.
Zero-size logical files need no payload object. A full-set verifier must
refuse incremental `base_size` or base-backup references it cannot resolve.

The corrected manifest keeps logical `num_files`/`total_size`, adds
`num_entries`, `uncompressed_size`, `compressed_size`, and records measured
`object_count`, `object_bytes`, `metadata_bytes`. The independent verifier
parses native XML itself; it does not merely trust the package's manifest.
Its local test against captured metadata passed and rejected missing,
extra and wrongly sized physical objects. Completed marker and restore runtime acceptance after this fix passed in
rehearsal 3; its independent storage evidence is recorded above.

## Hyphenated cluster name fails only when used as an unquoted SQL token

The first focused rehearsal failed creating its probe table with
`ON CLUSTER clickhouse-aws`. ClickHouse accepts the configured cluster name,
but the unquoted SQL token splits at the hyphen. The operator reproduced
`Code: 62` with the error position 75 at `-`; quoting the cluster name in the
statement corrected the probe. `evidence/live-rehearsal-1.txt` records the
failed task with its credentials correctly hidden by `no_log`; the code and
position came from the operator's separate direct-client reproduction.

Render the configured cluster as a quoted SQL name/string accepted by the
statement, with appropriate escaping. Reusing a value safely in XML does not
make it a valid bare SQL identifier. The subsequent successful rehearsal is
the runtime evidence for this correction.

## S3 encryption defaults produce drift after successful runtime acceptance

The full published-pin create 3 passed application acceptance and rehearsal,
but the final `tofu plan -detailed-exitcode` for `clickhouse-storage` returned
2. The only storage change shown was the backup encryption rule: AWS/provider
readback contained `blocked_encryption_types = ["SSE-C"]` and
`bucket_key_enabled = false`, while the template left both unspecified and
the proposed replacement rule contained `blocked_encryption_types = []`.
The redacted deployment artifact `evidence/live-create-3.txt` records this
actual plan and `OpenTofu drift remains in clickhouse-storage`.

The package correction explicitly denies SSE-C and sets
`bucket_key_enabled = false` alongside AES256, matching the observed bucket
configuration and keeping the denial rather than trying to remove it.
The corrected live storage plan now reports no changes with detailed-exitcode
0 (`evidence/encryption-no-change-plan.txt`). Source
`18ea94a3abd1dd8445eac1ea4e52bfcacd6ce321`, launcher publication `298b502`,
also passed isolated credential-free build/create-dry-run/delete-dry-run
(`evidence/offline-published-*.txt`). Complete pinned create 4 subsequently passed with exit 0, including the
final no-change drift gate (`evidence/live-create-4.txt`). Full and repeated
deletion also passed as recorded below.
This is an observed default/readback mismatch at the AWS provider pin 6.31.0;
it is not a claim that every older S3 bucket has these defaults.

## Final teardown and evidence limits

Published source `b3ebf393442d0a2e0d3bf5e2967cc1f59bab6d31` and launcher
`daeeb28f54475df68c87318ce86c7aa3d10c776a` passed full deletion with exit 0
(`evidence/live-delete-1.txt`): compute removal took 419456 ms and managed
backend finalization 28154 ms. `evidence/resources-after-delete.json` reported
PASS, `remaining_resource_count=0`, and no failures across the recorded
instances, EBS volumes, VPC dependencies, managed keypair, IAM identity,
state/backup buckets and Cloudflare records. Terminated EC2 descriptions may
remain as historical records; they are not running resources.

Repeated deletion also exited 0 (`evidence/live-delete-2.txt`), routing from
missing inventory to backend finalization with the bucket already absent
(1098 ms inventory read, 2196 ms finalization). `evidence/local-cleanup.json`
confirmed private/public SSH keys, profile aliases, local WireGuard config
and interface absent. Refreshed post-create continuity, health and storage
audits passed before deletion, and `evidence/offline-final-*.txt/json`
records passing final published-launcher checks.

This proves the tested functional lifecycle in one availability zone with a
controlled non-entry-replica stop/restart. It does not establish production
capacity, cross-AZ availability, abrupt disk-loss recovery, entry-node client
failover, or restoration after total Keeper loss. Backup contents were removed
as part of the explicitly managed disposable deployment lifecycle. The
independent skill evaluation diagnosed the tested support cases; static
validators and these support-case evaluations do not re-run cloud acceptance.
