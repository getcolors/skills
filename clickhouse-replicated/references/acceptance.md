# Acceptance doctrine

Exit codes are not evidence; each gate asks the cluster what it actually
has. The original Vultr in-play, application-host and replica-loss gates
were exercised on 2026-09-03 in `getcolors/langfuse` converge, smoke and
rehearsal, through that package's `create` and `rehearse`. The corrected
logical/physical backup protocol below comes from the September 10 AWS
counterexample and rehearsal; the AWS section identifies those newer
observations and remaining checks. The application-level gates (ingestion, read-back through
the API, the restore-and-boot) are in [`langfuse-multi-node`]'s acceptance
doctrine; this page is the ClickHouse operator's.

## In-play gates (every converge, on every node unless stated)

- **Health with retries**: `GET /ping` on loopback answers 200 (30 × 2 s).
  Only after `flush_handlers` restarted the server for a changed template,
  so the gate sees the configuration it will run with.
- **The cluster is a cluster**: `SELECT count() FROM
  clusterAllReplicas('default', system.one)` = 3 as `admin` (30 × 3 s — the
  replicas come up at different moments).
- **Keeper holds a quorum**: `SELECT count() FROM system.zookeeper WHERE
  path = '/'` > 0 (10 × 3 s).
- **Node 0 reaches node 1 with a credential**: `SELECT hostName() FROM
  remote('<node-1 vpc>:9000', system.one, 'admin', '<password>')` from node
  0 returns a non-empty name. Provider firewall, ufw, and the admin user's
  `<networks>` all have to be right for this to answer; the review asked for
  it after finding the ancestor's loopback-only admin would have failed
  distributed queries even with the firewall fixed.
- **`SELECT timezone()` = `UTC`** (answered without configuration on the
  Vultr Ubuntu image; the common play asserts the system timezone too).
- **`system.query_log` exists after `SYSTEM FLUSH LOGS`** — the table is
  lazy, and the application reads it.
- **The backup disk is registered** on node 0: `SELECT count() FROM
  system.disks WHERE name = 'backups'` = 1.
- **No credential in the query log** (node 0): flush, `SELECT query FROM
  system.query_log FORMAT TSVRaw`, and `grep -cF` for the backup secret read
  from the host's credential file — compared **on the host**, never by
  passing the secret into SQL, which would itself put it in the log.
- **An empty secret refuses to render** the users file (assert on all four
  generated secrets), and an empty backup credential refuses to install on
  node 0.
- **The monitor runs once** so `describe` has a result: `/ping`,
  `replication_queue` < 100, Keeper root readable, cluster = 3, disk < 80 %,
  and on node 0 the newest completed set younger than the desired-state
  threshold (30 h).

## From the application host (every converge)

- **The network says what the firewall says.** Raw TCP (`/dev/tcp`, never
  ping — the provider group passes ICMP on the private interface) to node 0
  on 8123 and 9000 succeeds, and a connection to Keeper 9181 is
  **refused**. The denial is the gate that separates a right firewall from
  a wide one.
- **The cluster from the application's identity**: `clusterAllReplicas` = 3
  and the Keeper root through the HTTP interface as the application user —
  which is what surfaced the missing `system.one` / `system.clusters` /
  `system.zookeeper` grants.
- **Replication is real**: rows written through node 0 are read back from
  the **last** replica (`system.clusters ... ORDER BY replica_num DESC LIMIT
  1`) within 60 s.
- **A wrong password is refused** on 8123 (`X-ClickHouse-Key` wrong → not
  200).

## The backup set protocol (`clickhouse-backup`, node 0)

1. `BACKUP DATABASE default TO Disk('backups', '<stamp>/') SETTINGS async =
   0 FORMAT TSV` → `id`, `status`; anything but `BACKUP_CREATED` fails.
2. Read logical `num_files`/`total_size` and physical `num_entries`,
   `uncompressed_size`, `compressed_size` for the returned backup id.
3. Read native `.backup` XML. Its logical file count and sum of logical sizes
   must equal `num_files`/`total_size`. Resolve each nonempty file to its
   `data_file` alias when present, otherwise its name, deduplicate physical
   paths and require consistent sizes. Include `.backup` itself, then require
   exact equality of that path/size map with the recursive S3 listing.
   For the measured full, uncompressed `s3_plain` sets, physical object count
   is `num_entries + 1`, and physical bytes equal `compressed_size` and
   `uncompressed_size`. Reject incremental/base references in a verifier that
   supports only full sets. This replaces the earlier, nonportable direct
   listing-to-`num_files`/`total_size` rule: see [the AWS counterexample](aws.md#logical-backup-files-are-not-physical-s3-objects).
4. Write the implementation's manifest (`manifest.txt` in the original
   Langfuse/R2 scripts; `manifest.json` in standalone ClickHouse/AWS), then
   `.complete` **last**, written with read-back. When checking a completed
   set again, exclude only that chosen manifest and `.complete` from the
   native physical map; all other objects must resolve from `.backup`.
   a set without a non-empty marker does not exist to restore or to
   freshness.
5. Prune completed sets past retention only while a newer completed set
   exists; incomplete sets older than a day are debris.

## The restore check (`clickhouse-restore-check`, node 0, in the rehearsal)

1. Choose the set: the newest completed set that has a later completed
   Postgres dump (`--pair`; the pairing rule is the application's, see
   `langfuse-multi-node`) or a named stamp that is complete.
2. `DROP DATABASE IF EXISTS restore_check SYNC`.
3. `RESTORE DATABASE default AS restore_check FROM Disk('backups',
   '<set>/') SETTINGS async = 0 FORMAT TSV` → status `RESTORED`.
4. `restore_check` has more than zero tables (13 on this build).
5. **Zero Keeper collisions**: no `restore_check` replica shares a
   `zookeeper_path` with a `default` replica (`system.replicas`).
6. A row count from the table the application actually writes
   (`events_full` on Langfuse v4).
7. After the application-side rehearsal, drop `restore_check` with `SYNC`.

## The drill: losing a replica (rehearsal)

Stop `clickhouse-server` on node 1; from the application host, ingest and
read back with it down (the application points at node 0); start node 1;
`SELECT count() FROM system.replication_queue` on node 1 reaches 0 (60 × 5
s). The stop and the probe are a `block` whose `always` starts the replica
and waits for the drain, so a failed probe cannot leave the deployment
degraded — the first version could, and the post-build inspection said so.
Verified on the live cluster: ingest and read passed with node 1 down, and
the queue drained to 0 after the restart.

## What was deliberately not gated

- **A node-0 loss.** The application has no client-side replica failover
  and points at node 0; losing it takes the application down while the data
  survives on two replicas. Stated in the companion's README, not drilled.
- **A coordinated snapshot across ClickHouse and Postgres.** The pairing
  rule bounds the inconsistency instead; that rule is the application's.
- **Per-object checksums or an incoming-to-final copy for backup sets.**
  Asked for by the post-build inspection, rejected as doubling the S3
  traffic of every nightly set. The earlier direct counter comparison was
  accepted in that review, but is superseded by the logical/physical mapping
  correction above; marker-last selection remains required.
- **Keeper snapshots or coordination-log backups.** The native `BACKUP`
  covers the tables; a full Keeper loss recovery was not rehearsed.

## Standalone AWS assessment gates — runtime rehearsal passed

The [AWS evidence ledger](aws.md) separates completed provisioning checks from
the completed runtime, convergence and deletion gates. The workload is dbt `analytics`, not Langfuse `default`.

- Native backup includes `analytics`; native logical metadata matches logical
  counters, and resolved physical files match the S3 path/size map and
  physical counters. Independent listing excludes `manifest.json` and
  `.complete` from those native-file checks and
  verifies native `.backup` metadata plus nonempty matching marker content.
- Scoped backup IAM credentials list the backup bucket but receive HTTP 403
  listing the state bucket; private/encrypted buckets and versioned state
  are checked independently with operator credentials.
- Restore `analytics AS restore_check`: compare actual `events_summary`
  contents and require zero Keeper collisions; always drop the scratch copy.
- Use a new outage probe ID every run, then require it on the surviving and
  recovered nodes and drain the recovered queue. Scope analytics replica
  counts so a persistent rehearsal table cannot break repeat convergence.
- From Metabase's private interface, HTTP succeeds and Keeper 9181 is denied.
  Public refusal and ICMP success do not substitute for this role gate.
- Repeat convergence preserves a separately recorded workload probe. Full
  deletion stops backup writers before removing their bucket; finalization
  retry still works after compute retirement. Repeated deletion and exact
  recorded EC2/EBS/VPC/key/IAM/bucket/DNS absence complete the lifecycle proof.

Focused runtime gates passed in `evidence/live-rehearsal-3.txt`, with
independent storage checks in `evidence/storage-isolation-1.json`: 53 logical
files/5313 bytes, 36 physical S3 objects/13895 bytes; restored analytics rows
matched, zero Keeper collisions, fresh-write outage/recovery, private Keeper
denial, and three healthy monitors. Continuity, health and storage audits after pinned create 3 also passed.
That create failed its final S3 drift gate with exit 2; complete convergence
after correction passed in create 4 (exit 0, `evidence/live-create-4.txt`);
full/repeated deletion subsequently passed in `evidence/live-delete-1.txt`
and `evidence/live-delete-2.txt`. Independent `resources-after-delete.json`
found zero remaining resources; `local-cleanup.json` confirmed managed
SSH keys/aliases and local WireGuard configuration/interface absent.

The AWS MTU correction has focused live evidence: the identical Python client
that hung reading `system.settings` initialized and returned `SELECT 1` in
under one second with all tunnel MTUs at 1420. Require this larger-response
path in addition to a tiny HTTP health query. This focused pass does not
substitute for complete published-pin convergence. The focused dbt and
backup/recovery sequence subsequently passed as recorded above.
