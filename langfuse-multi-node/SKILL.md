---
name: langfuse-multi-node
description: Everything a self-hosted Langfuse v4 on separate machines needs that the docs and the Compose quick start will not tell you - langfuse-web restart-looping on 'P3005 The database schema is not empty' against a brand-new Neon database, traces that never appear after a 207 from /api/public/ingestion ('Rejected N event(s) from the legacy /api/public/ingestion endpoint ... events_only mode'), GET /api/public/traces/<id> answering 404 while health is green, an empty traces table on a healthy ClickHouse, POST /api/public/media answering 201, ClickHouse failing to start with 'SAXParseException Invalid token' or 'PARTITION BY parameters should be specified directly inside engine', a BACKUP_CREATED that leaves randomly named objects in R2, 'Not enough privileges ... SHOW COLUMNS ON system.one', and SHOW timezone returning GMT. Use whenever the user runs Langfuse v4 on more than one host, puts its Postgres on Neon, or backs ClickHouse up to S3-compatible storage. Full symptom index at the top of the body.
---

# Langfuse v4 on separate machines

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim text in `references/failure-catalogue.md`:

- `langfuse-web` restart-loops on `Error: P3005 The database schema is not
  empty` right after the storage tier's own health check ran, and the two
  printed causes (connectivity, URL encoding) are both fine
- `Rejected N event(s) from the legacy /api/public/ingestion endpoint ...
  because this Langfuse v4 deployment runs in events_only mode` — the
  request answered 207, the raw event is in S3, the trace never appears
- `GET /api/public/traces/:id` is 404 for a trace that was just ingested;
  the same route answers 404 for a wrong key too
- `SELECT count() FROM traces` is 0 on a healthy v4 ClickHouse
- `POST /api/public/media` answers `201` and a gate written for `200` fails
- ClickHouse: `Failed to merge config ... SAXParseException: Invalid token`,
  `status=232/ADDRESS_FAMILIES`, empty `err.log`
- ClickHouse: `If 'engine' is specified for system table, PARTITION BY
  parameters should be specified directly inside 'engine'`, `Failed with
  result 'protocol'`
- `BACKUP DATABASE ... TO Disk(...)` returns `BACKUP_CREATED` and the bucket
  holds `agp/jjppeptxopeoqjzmlhpvtwrwopqkb`-style objects and nothing under
  the set prefix
- `Not enough privileges ... SHOW COLUMNS ON system.one` /
  `SELECT ON system.clusters` / `SELECT ... on restore_check.events_full`
- `SHOW timezone` returns `GMT` on a Neon compute
- "vultr already has an SSH key named `<profile>` that is not in this
  deployment's state" immediately after a successful create
- Ansible: `Destination directory /etc/colors does not exist`; `failed at
  splitting arguments` on a valid shell block; a Redis probe that "answered
  nothing"; a monitor calling a healthy container UNHEALTHY because Docker's
  `RestartCount` never forgets

Langfuse's own guidance is a single Docker Compose host for testing or
Kubernetes for production. This skill covers the shape in between — the
components Langfuse says should be separate, each on its own machine, with
the data tiers reachable only from the peer that needs them — measured on a
live build: fifteen converges against six Vultr instances, a four-round
adversarial plan review, two post-build inspection rounds, six rehearsal runs, and the restore-and-boot,
replica-loss and Redis-restart drills on the live hosts, all on 2026-09-03.

Everything here was verified against that running deployment unless it
says otherwise. Where this skill contradicts the docs, the live probe is the
authority, and the entry says which.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/langfuse`](https://github.com/getcolors/langfuse) Package Skill
— the OpenTofu for the VPC and the four role-scoped firewall groups, the
seven Ansible plays, the ClickHouse cluster configuration, the backup and
restore scripts, the smoke and the rehearsal — under
`green/src/resources/io/github/getcolors/langfuse/tools/`, copied byte for
byte into `red/resources` and blue's embedded `resources/` (the package ships
green, red and blue; `scripts/parity.sh` diffs the three renders), covered by
that repo's tests, goldens and launcher checks, and consumed by the
[`langfuse-vultr`](https://github.com/getcolors/langfuse-vultr) deployment.
The Neon storage tier is `getcolors/neon` rendered from a SHA pin, and its
own traps are the [`neon-single-node`] Context Skill's. This skill carries no
copies of any of it, per the Context Skill Standard's no-second-copy rule.
Read the templates there; read *why they are shaped that way* here.

## Topology that survived

Six machines in one VPC: a **Neon** host (storage broker, pageserver, one
safekeeper, Postgres 17 under `compute_ctl`), a **Redis** host, three
**ClickHouse** replicas each with a Keeper voter, and the **app** host
(`langfuse-web`, `langfuse-worker`, Caddy behind Cloudflare). Cloudflare R2
holds Neon's layers and WAL, Langfuse's raw events and media, and the
backups.

- **v4's default write mode is the contract.** A fresh Langfuse v4 runs
  `events_only`: the legacy batch endpoint rejects every event type but
  `score-create`/`sdk-log` (while answering 207), the legacy read routes are
  404 for everyone, and the rows live in `events_full`/`events_core` with
  `traces`/`observations` migrated and empty. Every gate — ingestion,
  read-back, ClickHouse evidence, the negative space — has to be written for
  that model: OTLP/HTTP JSON to `/api/public/otel/v1/traces` with
  `x-langfuse-ingestion-version: 4` (verified: root + generation readable
  through `GET /api/public/v2/observations?traceId=` within 4 s), scores via
  `POST /api/public/scores`, negatives on a v2 route.
- **The storage tier's smoke table is in the application database.** The
  imported Neon play proves its round-trip with `colors_smoke` inside
  `<neon-database>`, and Prisma refuses to baseline a non-empty schema
  (`P3005`). Drop it once, before the first boot, guarded on
  `_prisma_migrations` being absent. Any Neon-provisioned database handed to
  a Prisma application meets this.
- **Two firewalls per host, per peer.** A Vultr firewall group filters the
  private interface and passes ICMP while dropping TCP; the image ships ufw
  enabled with 22 alone. One group per role, every east-west rule a `/32`
  from the peer's actual address (`count` over static lengths in tofu —
  addresses are unknown at plan time), ufw mirroring it, and a gate that
  proves a **denial** (app → Keeper) beside the allows. Docker-published
  ports bypass ufw; the provider group carries them.
- **Secrets are born where they are consumed and cross hosts as facts.**
  Node 0 generates the ClickHouse admin, `langfuse`, interserver and cluster
  secrets and the other replicas `slurp` them with `delegate_to`; the app
  host reads the Neon, Redis and ClickHouse passwords the same way and
  writes its `host.env`. Lookups run on the controller and could never read
  a file that exists only on a host. Three secrets are operator-held on
  purpose: `ENCRYPTION_KEY`, `SALT`, the initial password — a backup is
  readable only with the first two.
- **ClickHouse cluster `default`**, so Langfuse migrates `ON CLUSTER`
  unaided; a cluster `<secret>` instead of a password per replica entry;
  `default_replica_path` with `{uuid}` — which is what makes `RESTORE ... AS
  restore_check` land on fresh Keeper paths (verified: zero collisions in
  `system.replicas`). The documented v4 grant list is exact and sufficient
  for Langfuse; the package's own gates need `system.one`,
  `system.clusters`, `system.zookeeper` and `restore_check.*` on top.
- **System log tables**: remove the six Langfuse never reads, keep
  `query_log` (v4 reads `system.query_log*`), bound with `<ttl>` — an
  `<engine>` override collides with the base config's `partition_by`.
- **The backup disk is `s3_plain`.** A `type=s3` disk writes random keys
  and keeps the paths in local metadata; the set is unreadable from any
  other node. `s3_plain` writes every file at its path, and the credential
  lives in the disk configuration, never in SQL or `query_log` (a gate greps
  the log host-side for the secret).
- **App points at node 0.** Langfuse has no client-side replica failover;
  the data survives on three replicas, the app reaches one. Stated, not
  hidden.

## Backups and the pairing rule

Three sets under `<profile>/` in the backup bucket, each with a completion
protocol — objects uploaded, verified by read-back, manifest, `.complete`
written **last**: Postgres dumps every six hours (`pg_dump` inside the
compute container — Ubuntu's client is 16, compute is 17), ClickHouse
native `BACKUP` nightly, media copied **additively** (`rclone copy`, never
`sync`; content-addressed and immutable, whole-prefix `rclone check` before
the marker). Raw events are not backed up: Langfuse calls that prefix a
30-day reprocessing buffer.

The two stores are not quiesced. At restore time a ClickHouse set pairs with
the **oldest Postgres dump completed after it**, so Postgres is always the
newer snapshot: every project a restored trace references exists; a project
created after the ClickHouse snapshot exists without its newest traces; a
ClickHouse set with no later dump is refused rather than paired backwards.
The first draft had this backwards (recorded the newest *earlier* dump);
the adversarial review caught it.

## Durability, measured

- A **replica loss** costs nothing: ingestion and reads continued with node
  1 stopped, and its `replication_queue` drained to 0 after restart.
- A **Redis restart** with a job queued costs nothing: the AOF kept it and
  the trace landed after the worker came back. A Redis **host** loss loses
  the queue; the raw events stay in R2 and Langfuse documents no replay.
- **Restore-and-boot** is the proof, not a row count: the pinned web image
  in a second Compose project on loopback, against the restored databases,
  with the operator-held keys and a fresh `NEXTAUTH_SECRET`, answers `GET
  /api/public/projects` with the live keys, returns the smoke trace's root
  and generation from `restore_check`, and decrypts the seeded LLM
  connection. Two markers: `.colors-ready` (service) and
  `.colors-recovery-verified` (recovery, with the paired stamps).
- **The Neon tier's RPO** is the neon-single-node one: the six-hourly dump
  is the real bound for the transactional tier.

## References

- `references/pins.md` — the verified version set and its generation rules.
- `references/failure-catalogue.md` — symptom-indexed verbatim errors.
- `references/acceptance.md` — the gates and the rehearsal, including what
  was deliberately not gated.
