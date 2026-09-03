---
name: clickhouse-replicated
description: What a three-node replicated ClickHouse cluster with embedded Keeper needs that the docs will not tell you - clickhouse-server failing to start with 'SAXParseException Invalid token', status=232/ADDRESS_FAMILIES and an empty err.log; 'PARTITION BY parameters should be specified directly inside engine' and 'Failed with result protocol' after a config.d override on system.query_log; BACKUP TO Disk answering BACKUP_CREATED while the bucket holds only randomly named objects (s3 versus s3_plain); a test restore beside the live database that must not collide in Keeper; 'Not enough privileges ... SHOW COLUMNS ON system.one' with the documented grants; replicas that ping each other while clusterAllReplicas never reaches 3 on Vultr (provider firewall and ufw both filter the VPC); system.query_log absent until SYSTEM FLUSH LOGS. Use whenever the user runs ClickHouse replicas with Keeper on separate hosts, backs ClickHouse up to S3 storage, or test-restores on a live cluster. Full symptom index at the top of the body.
---

# Replicated ClickHouse with embedded Keeper on three hosts

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim text in `references/failure-catalogue.md`:

- `clickhouse-server` will not start; `systemctl` says `status=232/ADDRESS_FAMILIES`,
  `err.log` is empty, and only `journalctl` carries `Failed to merge config
  with '.../config.d/<file>.xml': SAXParseException: Invalid token`
- `clickhouse-server` will not start; `systemctl` says `Failed with result
  'protocol'` or "the service did not take the steps required by its unit
  configuration", `err.log` is a stack trace, and `clickhouse-server.log` has
  `Code: 36 ... If 'engine' is specified for system table, PARTITION BY
  parameters should be specified directly inside 'engine'`
- every peer port shows CLOSED from the other nodes while the server is down
  — and the firewall is not the cause
- `BACKUP DATABASE ... TO Disk(...)` answers `BACKUP_CREATED` but the bucket
  holds `agp/jjppeptxopeoqjzmlhpvtwrwopqkb`-style objects and nothing under
  the set prefix; a verifier says `no objects under <stamp>/`
- a restored copy must live beside the live database on the same cluster and
  you are not sure the replicated tables will get their own Keeper paths
- an application booted against the restored database answers 500 on every
  read (`ACCESS_DENIED` on `restore_check.*`)
- `Not enough privileges ... SHOW COLUMNS ON system.one` /
  `SELECT ON system.clusters` from a user that carries exactly the grants the
  application documents
- three replicas ping each other, `clusterAllReplicas('default', system.one)`
  never reaches 3, Keeper has no quorum, and no error names the firewall
- `system.query_log` does not exist on a freshly started server
- a converge of several machines dies with no error of its own at exactly ten
  minutes

This skill covers one shard of three replicas on three machines, each
running its own Keeper voter inside `clickhouse-server`, reachable only over
a VPC, backed up natively to Cloudflare R2, and restored beside itself as a
rehearsal — as the ClickHouse tier of the `getcolors/langfuse` build, measured
on the live platform on 2026-09-03: thirteen live converges and four
rehearsal runs against three Vultr instances (the twelve converges and three
rehearsals the session notes record verbatim, plus one converge-and-rehearse
after the post-build inspection's fixes), a four-round adversarial plan review
and a two-round post-build inspection, and the replica-loss drill on the live
hosts.

Everything here was verified against that running cluster unless it says
otherwise. Where this skill contradicts the ClickHouse or Langfuse docs, the
live probe is the authority, and the entry says which. The application-side
consequences of the same build — the Langfuse v4 write mode, the Prisma trap,
the restore-and-boot through the app — are the
[`langfuse-multi-node`](https://www.getcolors.ai/getcolors/skills/langfuse-multi-node)
Context Skill's; this skill does not repeat them, only links to them.

## The reference implementation, and why this skill ships no assets

The tested working files live in the
[`getcolors/langfuse`](https://github.com/getcolors/langfuse) Package Skill,
which owns the ClickHouse tier as its own templates under
`src/resources/io/github/getcolors/langfuse/tools/`:

- `ansible/clickhouse.yml` — the play: exact-version apt install, secrets born
  on node 0, the two XML templates, the backup disk, the gates, the timers;
- `ansible/clickhouse-config.xml` — cluster, Keeper, macros, replica path,
  the system log tables;
- `ansible/clickhouse-users.xml` — the three users and the XML grants;
- `ansible/clickhouse-backup.xml` — the `s3_plain` backup disk (node 0);
- `ansible/clickhouse-backup.sh`, `clickhouse-restore-check.sh`,
  `clickhouse-monitor.sh` — the set protocol, the restore beside the live
  database, the health check `describe` reads;
- `ansible/common.yml` and `infrastructure/main.tf` — ufw and the Vultr
  firewall group, rule for rule.

They are covered by that repo's tests, goldens and launcher checks and
consumed by the `langfuse-vultr` deployment. Their ancestor is the
[`getcolors/clickhouse`](https://github.com/getcolors/clickhouse) package —
three Hetzner nodes with Keeper, Metabase and dbt, a WireGuard client path,
static private addresses and a per-replica admin password in
`remote_servers`; the `langfuse` templates are credited to it in their
headers and diverge on every point this skill names. Claims here come from
the 2026-09-03 build; nothing from the Hetzner ancestor is asserted unless it
was re-verified on that build. This skill carries no copies of any of it, per
the Context Skill Standard's no-second-copy rule. Read the templates there;
read *why they are shaped that way* here.

## Topology that survived

Three `vc2-4c-8gb` Vultr instances (Ubuntu 24.04) in one VPC, cluster
`default`, one shard, `internal_replication` on, and on every node one
`keeper_server` block inside the server config — no separate
`clickhouse-keeper` process. `server_id` is the node's ordinal plus one
(Keeper ids start at 1), `<macros>` are `shard=01`, `replica=node-<ordinal>`,
and `default_replica_path` is `/clickhouse/tables/{uuid}/{shard}` — the
`{uuid}` is load-bearing later. Ports: 8123 HTTP, 9000 native, 9009
interserver, 9181 Keeper client, 9234 raft. Every address in the rendered
XML comes from the inventory at converge time, so a replaced instance
re-renders its peers on the next converge; the Hetzner ancestor baked them in.

- **Secrets are born on node 0 and cross hosts as facts.** `openssl rand
  -hex 24` behind `creates:` makes the admin password, the application
  password, the interserver credential and the cluster secret once; the
  other replicas `slurp` them with `delegate_to` and keep a `0600` copy. The
  users file carries `password_sha256_hex` computed by Jinja's
  `hash('sha256')`, so no plaintext password is rendered outside the secrets
  directory, and an assert refuses to render users with an empty secret.
- **A cluster `<secret>` in `remote_servers`, no `<user>`/`<password>` per
  replica.** With it, distributed queries run on the remote nodes as the
  initiating user, and the users file is the one place credentials live.
  The ancestor put the admin password in every replica entry. Verified by
  the gates: `clusterAllReplicas('default', system.one)` = 3 from every node
  and an authenticated `remote()` from node 0 to node 1.
- **`interserver_http_credentials`** (user `interserver` plus the generated
  secret) on the interserver port, with `interserver_http_host` set to the
  VPC address so part exchange never tries the public interface.
- **The application points at node 0.** Langfuse has no client-side replica
  failover; the data survives on three replicas, the client reaches one. The
  replica-loss drill therefore stopped node **1**; a node-0 loss was not
  drilled and would take the application with it.

## The four configuration facts that cost converges

Full entries with verbatim text in `references/failure-catalogue.md`.

1. **XML comments must not contain `--`.** A templated comment reading
   "stay -- v4 reads" made the whole `config.d` file unparseable. The server
   dies before logging is configured: `err.log` is empty, systemd reports
   `status=232/ADDRESS_FAMILIES` (which points nowhere near the cause), and
   only `journalctl -u clickhouse-server` carries the Poco
   `SAXParseException` with the line and column. `python3 -c 'import
   xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])'` reproduces it
   offline in a second; the companion's golden check now parses every
   rendered `clickhouse-*.xml` that way.
2. **Bound the system log tables with `<ttl>`, never an `<engine>`
   override.** The packaged `config.xml` already sets `<partition_by>` for
   `query_log`, `part_log` and `error_log`; a `config.d` fragment that adds
   `<engine>` (the shape Langfuse's docs give as the "aggressive TTL"
   option) merges *beside* that `partition_by` and the server refuses to
   start with `Code: 36 ... BAD_ARGUMENTS`. Because the unit is
   `Type=notify` and never notifies, systemd reports `Failed with result
   'protocol'`; the real message is in `clickhouse-server.log`, not
   `err.log`. `<ttl>event_date + INTERVAL 30 DAY DELETE</ttl>` per table
   merges cleanly; TTL applies when the table is first created. The six log
   tables the application never reads (`trace_log`, `text_log`,
   `opentelemetry_span_log`, `asynchronous_metric_log`, `metric_log`,
   `latency_log`) are removed with `remove="1"`; `query_log` stays because
   Langfuse v4 reads `system.query_log*`.
3. **`system.query_log` is created lazily.** On a fresh server it does not
   exist until the first flush; a gate that checks for it runs `SYSTEM
   FLUSH LOGS` first and then counts it in `system.tables`.
4. **Grants live in XML on a `users.d` user, and the application's list is
   not the operator's.** `<grants><query>GRANT ...</query></grants>` on the
   `langfuse` user carries exactly the grants Langfuse v4 documents —
   including `GRANT READ ON REMOTE` and `GRANT CLUSTER ON *.*`, with which
   the application's bundled migrations ran `ON CLUSTER default` unaided on
   26.3 — and that list does **not** cover what a package's own gates ask:
   `SELECT ON system.one` (for `clusterAllReplicas`), `system.clusters`,
   `system.zookeeper`, and `SELECT ON restore_check.*` for the database the
   rehearsal restores into. Each of those failed once with `Not enough
   privileges` and is labelled in the users file as the package's, not the
   application's. `SELECT timezone()` answered `UTC` out of the box.

## Backups: the disk is the credential boundary

Node 0 carries a `storage_configuration` disk named `backups` whose endpoint
is `<r2-endpoint>/<bucket>/<profile>/clickhouse/` and whose access key and
secret sit in that `config.d` file (`0600`, owned by `clickhouse`,
`use_environment_credentials` off), with `<backups><allowed_disk>backups
</allowed_disk></backups>` so a statement can name that disk and nothing
else. `BACKUP DATABASE default TO Disk('backups', '<stamp>/')` therefore
carries no credential — not in SQL, not on a command line, and not in the
thirty days of `system.query_log`; a gate greps the flushed log **on the
host** for the secret rather than passing the secret into a query.

- **The disk type is `s3_plain`, not `s3`.** A `type=s3` disk stores objects
  under random keys and keeps the path mapping in local metadata under
  `/var/lib/clickhouse/disks/<name>/`: the first backup returned
  `BACKUP_CREATED` with 270 files and left 128 randomly named objects that
  only that node could ever read back. `s3_plain` writes every file at its
  own path — the set is listable (`.backup`, `data/`, `metadata/`) and
  restorable from anywhere. Switching a live node between the two types
  means stopping the server, removing the old local metadata directory and
  purging the stray objects; the companion's notes record exactly that
  one-off on node 0.
- **A set counts only when the bucket equals `system.backups`.** `BACKUP ...
  SETTINGS async = 0 FORMAT TSV` returns the backup id and status; the
  script reads `num_files` and `total_size` for that id from
  `system.backups` and requires the recursive listing under `<stamp>/` to
  match both, plus ClickHouse's own `.backup` metadata file (written last).
  The post-build inspection asked for an incoming-to-final copy with
  per-object checksums; that was rejected as doubling the S3 traffic of every
  nightly set, and the equality check was accepted as the evidence that adds
  something. Only then the manifest, and the `.complete` marker **last**,
  written with read-back — restore picks completed sets only, and a 0-byte
  marker satisfies an existence check forever.
- **Timers**: the set nightly on node 0 only, the monitor every fifteen
  minutes on every node, and the monitor's backup-age check runs only where
  the backup credential file exists.

## Restore beside the live database

`RESTORE DATABASE default AS restore_check FROM Disk('backups', '<set>/')`
on the live cluster, after `DROP DATABASE IF EXISTS restore_check SYNC`. The
adversarial review rightly doubted that a *database name* could give the
restored replicated tables fresh Keeper paths — it cannot; the mechanism is
`{uuid}` in `default_replica_path` plus the new UUIDs RESTORE assigns, and
the rehearsal proves it every run: zero rows in `system.replicas` where a
`restore_check` table's `zookeeper_path` equals a `default` one's (verified:
13 tables restored, 0 collisions). The stated fallback, never needed, was a
scratch ClickHouse container with its own embedded Keeper on node 0.

Two things the restore taught beyond ClickHouse: the application user needs
`SELECT ON restore_check.*` if the application is ever booted against the
restored copy (the scratch web answered 500 on every read until it had it),
and on Langfuse v4 the proof of a restored set is a count of `events_full`,
not `traces` — that half of the story is [`langfuse-multi-node`]'s. The
pairing rule that decides which Postgres dump goes with a ClickHouse set is
also that skill's.

## Two firewalls, both filtering the private interface

A Vultr firewall group filters the VPC interface as well as the public one,
and selectively: ICMP passes while TCP is dropped. The Ubuntu image ships
`ufw` **enabled** with a single `22/tcp` rule, and ufw filters the VPC
interface too. ClickHouse runs natively — no Docker chain bypasses ufw — so
both layers are load-bearing for the cluster and both must carry the same
rules: 9000, 9009, 9181 and 9234 from each replica's actual VPC address as
a `/32`, 8123 and 9000 from the application host's, nothing from anyone
else. In OpenTofu the east-west rules are `count` over static lengths, not
`for_each` over addresses, because the addresses are unknown at plan time
(the template's comment records the plan error; the build used `count`
from the start). This build did not fail on the firewall — the rules were in
place from converge 1 — so the "ping works, TCP dropped, quorum never forms"
shape is carried from the companion's templates and earlier Vultr builds in
this workspace, and was exercised here by the gates rather than re-hit: raw
TCP allows to 8123/9000 from the app host, the authenticated cross-node
`remote()`, and a **denial** — the app host refused on Keeper 9181 — so an
allow-only gate cannot mistake a wide firewall for a right one.

## Durability, measured

- **Replica loss costs nothing.** Node 1 stopped; ingestion and reads through
  the application (which talks to node 0) continued; node 1 started;
  `system.replication_queue` drained to 0. The stop and the start are one
  Ansible `block`/`always`, so a failed probe cannot leave the replica down
  — the post-build inspection found the first version could.
- **The monitor's thresholds**: `/ping`, `replication_queue` depth under 100,
  Keeper root readable, `clusterAllReplicas` = 3, disk under 80 %, newest
  completed set younger than the desired-state maximum (30 h for a nightly
  set). Written to a JSON file `describe` reads over SSH.
- **Ten minutes is the ceiling of an agent's tool call, not of a converge.**
  A six-machine converge was killed mid-Ansible with no error of its own.
  Run converges detached and read the log; a killed Ansible run resumes
  idempotently.

## References

- `references/pins.md` — the verified version set and its generation rules,
  with retest conditions.
- `references/failure-catalogue.md` — symptom-indexed verbatim errors.
- `references/acceptance.md` — the gates, the set protocol, the restore
  check and the drill, including what was deliberately not gated.
