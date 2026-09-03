# Failure catalogue

Symptom-indexed, verbatim where the error was verbatim. Every entry was hit
on the live cluster at the pins in `pins.md` — the ClickHouse tier of the
`getcolors/langfuse` build on 2026-09-03 — unless it says otherwise. The
application-side entries of the same build (Prisma `P3005`, the v4
`events_only` write mode, the Neon `GMT` timezone, the media `201`, the
Redis probe, Docker's `RestartCount`, the Ansible parent-directory and
apostrophe traps, the Vultr SSH-key ownership trap) are in the
[`langfuse-multi-node`](https://www.getcolors.ai/getcolors/skills/langfuse-multi-node)
catalogue and are not repeated here.

## `clickhouse-server` will not start: `status=232/ADDRESS_FAMILIES`, empty `err.log`

```
fatal: [langfuse-vultr-clickhouse-0]: FAILED! => {"changed": false, "msg": "Unable to start service clickhouse-server: Job for clickhouse-server.service failed because the control process exited with error code.\nSee \"systemctl status clickhouse-server.service\" and \"journalctl -xeu clickhouse-server.service\" for details.\n"}
systemd: clickhouse-server.service: Main process exited, code=exited, status=232/ADDRESS_FAMILIES
journalctl: Poco::Exception. Code: 1000, e.code() = 0, Exception: Failed to merge config with '/etc/clickhouse-server/config.d/colors-cluster.xml': SAXParseException: Invalid token in '/etc/clickhouse-server/config.d/colors-cluster.xml', line 62 column 48
```

On all three nodes at once. The systemd status names an address-family
problem and has nothing to do with the cause; `err.log` is **empty** because
the server dies while merging configuration, before logging is configured;
only `journalctl -u clickhouse-server` carries the Poco exception, and it
gives the line and column. Line 62 column 48 was inside an XML **comment**
that contained `--` ("stay -- v4 reads"), which XML forbids inside comments.
Any `config.d` fragment is merged into the whole configuration, so one bad
comment takes the server down, not one setting.

Fix: rewrite the comment (no `--` inside `<!-- -->`), and gate every
rendered XML file offline before it reaches a host:

```sh
python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])' /path/to/rendered.xml
```

It reproduces the exact position in under a second; the companion's golden
check runs it over every rendered `clickhouse-*.xml`.

## `clickhouse-server` will not start: `Failed with result 'protocol'`, `Code: 36 ... PARTITION BY parameters should be specified directly inside 'engine'`

```
fatal: ... "Unable to restart service clickhouse-server: Job for clickhouse-server.service failed because the service did not take the steps required by its unit configuration."
systemd: clickhouse-server.service: Failed with result 'protocol'.
clickhouse-server.log: <Error> Application: Code: 36. DB::Exception: If 'engine' is specified for system table, PARTITION BY parameters should be specified directly inside 'engine' and 'partition_by' setting doesn't make sense. (BAD_ARGUMENTS)
```

The unit is `Type=notify`; a server that exits during startup never
notifies, so systemd reports a *protocol* failure ("did not take the steps
required by its unit configuration") whatever the cause. This time
`err.log` held only a stack trace; the message is in
`clickhouse-server.log`. The packaged `config.xml` already sets
`<partition_by>` for `query_log`, `part_log` and `error_log`; a `config.d`
override that adds `<engine>ENGINE = MergeTree ... TTL ...</engine>` for
those tables — the shape Langfuse's scaling docs give as the "aggressive
TTL" option — merges *beside* the base `partition_by` and is refused.

Fix: bound the tables with the `ttl` setting, which merges cleanly:

```xml
<query_log><ttl>event_date + INTERVAL 30 DAY DELETE</ttl></query_log>
<part_log><ttl>event_date + INTERVAL 30 DAY DELETE</ttl></part_log>
<error_log><ttl>event_date + INTERVAL 30 DAY DELETE</ttl></error_log>
```

TTL applies when the table is first created. Remove the log tables nothing
reads with `<trace_log remove="1"/>` and so on (`trace_log`, `text_log`,
`opentelemetry_span_log`, `asynchronous_metric_log`, `metric_log`,
`latency_log` on this build) rather than trying to bound them; keep
`query_log` if the application reads `system.query_log*` (Langfuse v4 does).
Do not edit the packaged `config.xml` in place: the package upgrade will
overwrite it.

## Every peer port CLOSED from the other nodes — while the server is down

Seen beside both start failures above: probes of 9000/9009/9181/9234 from
the other replicas all report closed. Nothing listens because the process is
not up; this is a consequence, not a second fault. Read the server's own
logs before touching the firewall. The firewall shape that *does* stop a
cluster from forming is the next entry.

## Replicas ping each other, `clusterAllReplicas` never reaches 3, Keeper has no quorum, nothing names the firewall

Carried from the companion's templates and earlier Vultr builds in this
workspace; on the 2026-09-03 build the rules were in place from the first
converge and this shape was exercised by the gates (allows on 8123/9000
from the app host, the cross-node `remote()` query, the denial on 9181)
rather than re-hit as a failure. Two layers filter the VPC interface on a
Vultr Ubuntu image: the Vultr firewall group (which passes ICMP and drops
TCP on the private interface, so `ping` proves nothing) and `ufw`, which
ships **enabled** with a single `22/tcp` rule. ClickHouse runs natively, so
no Docker chain bypasses ufw for it. Every replica must admit every other
replica on 9000 (distributed queries), 9009 (part exchange), 9181 (Keeper
client) and 9234 (raft), as `/32` rules from the peers' actual VPC
addresses in **both** layers, and the application host on 8123 and 9000
only. Gate the allows with raw TCP (`/dev/tcp`, never ping) and gate one
denial — the app host on 9181 — or an allow-only gate cannot tell a wide
firewall from a right one.

In OpenTofu, build the east-west rules with `count` over static lengths (node
count × port count) rather than `for_each` over addresses: the addresses are
known only after apply, and a `for_each` keyed on them fails the plan (the
template's comment records `value depends on resource attributes that cannot
be determined until apply`; the build used `count` from the start, so that
error was not reproduced on 2026-09-03).

## `BACKUP ... TO Disk('backups', ...)` answers `BACKUP_CREATED`; the bucket holds random objects; `no objects under <stamp>/`

```
fatal: [langfuse-vultr-clickhouse-0]: ... "cmd": ["/usr/local/sbin/clickhouse-backup"] ... "stderr": "clickhouse-backup: no objects under 20260903T065949Z/"
```

`BACKUP DATABASE default TO Disk('backups', '<stamp>/')` had returned
`BACKUP_CREATED` and `system.backups` reported 270 files, and the bucket
prefix held **128 objects with random names** (`agp/jjppeptxopeoqjzmlhpvtwrwopqkb`,
…) and nothing under `<stamp>/`. R2 was not mangling keys: a disk of
`<type>s3</type>` stores objects under random keys and keeps the path
mapping in local metadata under `/var/lib/clickhouse/disks/<name>/`, so the
set is readable only from that node, and never by a listing. A backup
destination must be `<type>s3_plain</type>`, which writes every file at its
own path (`.backup`, `data/…`, `metadata/…`) and is listable and restorable
from anywhere.

Switching an existing disk's type on a live node: stop the server, remove
the old local metadata directory (`/var/lib/clickhouse/disks/backups/` here),
purge the stray objects, start. The disk registers again under the new type
(`SELECT count() FROM system.disks WHERE name = 'backups'` = 1 is the gate).

Verify a set by equality, not existence: the recursive listing under
`<stamp>/` must equal `num_files` and `total_size` from `system.backups` for
the backup id the statement returned (`SETTINGS async = 0 FORMAT TSV`
returns `id<TAB>status`), and `.backup` — which ClickHouse writes last — must
be present. Only then write the manifest and, last, the `.complete` marker.

## `RESTORE DATABASE default AS restore_check`: will the replicated tables collide in Keeper?

Not an error, a review finding: the plan first claimed the restored
*database name* gave fresh Keeper paths, and the reviewer was right that a
database name is not part of `/clickhouse/tables/{uuid}/{shard}`. The actual
mechanism is `{uuid}` in `default_replica_path` plus the new UUIDs RESTORE
assigns to the restored tables. Prove it on every restore:

```sql
SELECT count() FROM system.replicas
WHERE database = 'restore_check'
  AND zookeeper_path IN (SELECT zookeeper_path FROM system.replicas WHERE database = 'default')
```

must be 0 (verified: 13 tables restored, 0 collisions), and drop the scratch
database with `DROP DATABASE IF EXISTS restore_check SYNC` before the next
run. If a replica-path template without `{uuid}` is in use, restore into a
scratch server with its own Keeper instead — that was the stated fallback,
never needed here.

## The application answers 500 on every read against the restored database

```
FAIL  R3 the smoke trace ccff91dafa00650c0b8ba9fd87bc57fe answered 500 through the scratch web
```

The application user's grants were `ON default.*` only, so the copy of the
application booted against `restore_check` got `ACCESS_DENIED` inside and
turned it into HTTP 500. The rehearsal database is part of the contract:
`GRANT SELECT ON restore_check.*` on the application user, labelled as the
package's own grant. (On Langfuse v4 the restored proof is a count of
`events_full`, not `traces` — the [`langfuse-multi-node`] side.)

## `Not enough privileges ... SHOW COLUMNS ON system.one` / `SELECT ON system.clusters`

```
Code: 497. DB::Exception: langfuse: Not enough privileges. To execute this query, it's necessary to have the grant SHOW COLUMNS ON system.one. (ACCESS_DENIED) (version 26.3.29.7 (official build))
Code: 497. DB::Exception: langfuse: Not enough privileges. To execute this query, it's necessary to have the grant SELECT ON system.clusters. (ACCESS_DENIED)
```

From `SELECT count() FROM clusterAllReplicas('default', system.one)` and a
read of `system.clusters` as the application user, which carried exactly the
grant list the application documents. That list is sufficient for the
application — its `ON CLUSTER default` migrations ran with it, `GRANT READ
ON REMOTE` and `GRANT CLUSTER ON *.*` included — and insufficient for an
operator's gates. Add, and label as the package's: `GRANT SELECT ON
system.one`, `GRANT SELECT ON system.clusters`, `GRANT SELECT ON
system.zookeeper` (Keeper root readable), and `GRANT SELECT ON
restore_check.*` (previous entry). Grants go in XML on the `users.d` user:

```xml
<grants>
  <query>GRANT SELECT, INSERT ON default.*</query>
  ...
  <query>GRANT SELECT ON system.one</query>
</grants>
```

so the user, its `password_sha256_hex`, its `<networks>` and its grants are
one rendered file, applied on restart, with no `CREATE USER`/`GRANT` SQL to
sequence.

## `system.query_log` does not exist on a freshly started server

The table is created lazily on the first flush. A gate (or an application
that reads `system.query_log*` on boot) that looks for it right after start
sees nothing. `SYSTEM FLUSH LOGS` first, then
`SELECT count() FROM system.tables WHERE database = 'system' AND name =
'query_log'` = 1. The same flush precedes the credential grep of the log.

## The converge dies at ten minutes with no error of its own

An agent's tool call has a ten-minute ceiling; a converge of several
machines (250 s of Ansible on this build after the ClickHouse packages were
cached, longer on the first run with the apt install) can exceed it, and the
kill leaves no ClickHouse or Ansible error — the run simply stops. Run
converges detached (`setsid nohup ... &`) and watch the log; a killed
Ansible run resumes idempotently, and the exact-version apt step is a no-op
the second time.
