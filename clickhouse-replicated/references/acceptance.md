# Acceptance doctrine

Exit codes are not evidence; each gate asks the cluster what it actually
has. All of these ran against the live three-replica cluster on 2026-09-03
inside the `getcolors/langfuse` converge (`ansible/clickhouse.yml`), the
application-host smoke (`ansible/langfuse-smoke.sh`) and the rehearsal
(`ansible/rehearsal.yml`), and are repeatable with that package's `create`
and `rehearse`. The application-level gates (ingestion, read-back through
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
2. `num_files` and `total_size` for that `id` from `system.backups`.
3. The recursive listing under `<stamp>/` (via rclone on an `s3_plain`
   layout) has at least one object, includes `.backup` (ClickHouse writes
   it last), and its count and byte total **equal** step 2 — a partial
   upload or a scattering disk type fails here, not at restore time.
4. `manifest.txt` (stamp, completion time, ClickHouse version, table count,
   object count, bytes), then `.complete` **last**, written with read-back;
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
  traffic of every nightly set; the set-equality check against
  `system.backups` was accepted as the evidence that adds something, and
  the marker-last protocol already keeps a partial set from being selected.
- **Keeper snapshots or coordination-log backups.** The native `BACKUP`
  covers the tables; a full Keeper loss recovery was not rehearsed.
