# Failure catalogue

Symptom-indexed, verbatim where the error was verbatim. Every entry was hit
on the live build at the pins in `pins.md` — twelve converges and three
rehearsal runs against six Vultr machines on 2026-09-03 — unless it says
otherwise.

## Prisma `P3005` on Langfuse's first boot — the storage tier put a table there

```
Prisma schema loaded from packages/shared/prisma/schema.prisma
Datasource "db": PostgreSQL database "langfuse", schema "public" at "10.50.0.3:55433"
436 migrations found in prisma/migrations
Error: P3005
The database schema is not empty. Read more about how to baseline an existing production database: https://pris.ly/d/migrate-baseline
Applying database migrations failed. Common causes:
  1. The database is unavailable or unreachable.
  2. DATABASE_URL / DIRECT_URL credentials contain special characters that are not URL-encoded.
```

`langfuse-web` restart-loops on this while the worker logs `relation
"monitors" does not exist`. Neither hint is the cause. Prisma refuses to
apply migrations to a non-empty schema that has no `_prisma_migrations`
table yet, and the schema is non-empty because the **imported Neon play's
smoke gate creates `colors_smoke` inside the application database** on every
converge — the storage tier proves its SQL round-trip in the very database
the application is about to baseline. Fix: before the first boot only (when
`to_regclass('public._prisma_migrations')` is null), `DROP TABLE
colors_smoke`; later converges recreate it and Prisma no longer cares. Any
package that hands a Neon-provisioned database to a Prisma application will
meet this.

## `Rejected N event(s) from the legacy /api/public/ingestion endpoint ... events_only mode`

```
warn  Rejected 2 event(s) from the legacy /api/public/ingestion endpoint for project langfuse-vultr because this Langfuse v4 deployment runs in events_only mode. These events were not stored. Upgrade the client or integration to a v4-compatible SDK.
```

The request itself answers **207**, so a gate that checks the status sees
success, and the raw-event object still lands in R2 (Langfuse writes the
payload to S3 before deciding). The trace never appears. A fresh v4
deployment defaults to `LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only`:
`/api/public/ingestion` rejects every event type except `score-create` and
`sdk-log`, and `GET /api/public/traces/:id`, `/observations`, `/sessions`,
`/scores` (v1/v2) are **404 for everyone** — which also breaks a negative
gate that expects 401 on those routes. Ingest through OTLP/HTTP JSON at
`/api/public/otel/v1/traces` with `x-langfuse-ingestion-version: 4` (without
the header data appears up to ten minutes late), read through `GET
/api/public/v2/observations?traceId=...`, create scores with `POST
/api/public/scores`, and put the negative gates on a v2 route. Verified:
root span + generation readable within 4 s of the OTLP POST.

## ClickHouse evidence: `traces` and `observations` stay empty

On v4 in `events_only` the rows are in `events_full` (one row per span:
`trace_id`, `span_id`, `type`, `trace_name`, `tags`, …) and its projection
`events_core`; scores are in `scores` (`trace_id`, `observation_id`). The
`traces` and `observations` tables exist, are migrated, and hold **zero
rows**. `SELECT count() FROM traces WHERE id = ...` proves nothing on v4.

## `POST /api/public/media` answers 201, not 200

The media flow works exactly as documented — `POST` returns `{mediaId,
uploadUrl}`, `PUT` to the presigned R2 URL with `Content-Type` and
`x-amz-checksum-sha256` returns 200, `PATCH /api/public/media/{id}` with
`uploadedAt`/`uploadHttpStatus` returns 200, `GET` returns a download `url`
— but the create answers **201**. A gate written to the reference's "200"
fails a working path. Presigned URLs are virtual-hosted
(`<bucket>.<account>.r2.cloudflarestorage.com`) and need no CORS from a
non-browser client; UI rendering does, and only an Admin R2 token can set
bucket CORS, so it is an operator step.

## `SHOW timezone` returns `GMT` on the Neon compute

Neon's compute spec sets no `TimeZone`, so Postgres reports the compiled
default `GMT`. Langfuse requires the literal `UTC` on both databases. Fix
without touching the imported templates: `ALTER DATABASE <db> SET timezone
TO 'UTC'` by the owning role; new sessions inherit it. ClickHouse answered
`UTC` out of the box.

## `Not enough privileges. To execute this query, it's necessary to have the grant SHOW COLUMNS ON system.one`

```
Code: 497. DB::Exception: langfuse: Not enough privileges. To execute this query, it's necessary to have the grant SHOW COLUMNS ON system.one. (ACCESS_DENIED)
Code: 497. DB::Exception: langfuse: Not enough privileges. To execute this query, it's necessary to have the grant SELECT ON system.clusters. (ACCESS_DENIED)
```

The documented v4 grant list is exactly what Langfuse needs and nothing
more: `clusterAllReplicas('default', system.one)` and reading
`system.clusters` / `system.zookeeper` are the *package's* gates and need
their own `GRANT SELECT` lines, labelled as such.

## ClickHouse: `Failed to merge config ... SAXParseException: Invalid token`

```
Poco::Exception. Code: 1000, e.code() = 0, Exception: Failed to merge config with '/etc/clickhouse-server/config.d/colors-cluster.xml': SAXParseException: Invalid token in '/etc/clickhouse-server/config.d/colors-cluster.xml', line 62 column 48
systemd: clickhouse-server.service: Main process exited, code=exited, status=232/ADDRESS_FAMILIES
```

The systemd status names an address-family problem; the server's
`err.log` is empty because it dies before logging is configured; only
`journalctl -u clickhouse-server` carries the Poco exception. Line 62 was
an XML **comment** containing `--`, which XML forbids inside comments.
`python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])'`
reproduces it offline in a second and now guards every rendered XML file.

## ClickHouse: `If 'engine' is specified for system table, PARTITION BY parameters should be specified directly inside 'engine'`

```
<Error> Application: Code: 36. DB::Exception: If 'engine' is specified for system table, PARTITION BY parameters should be specified directly inside 'engine' and 'partition_by' setting doesn't make sense. (BAD_ARGUMENTS)
systemd: clickhouse-server.service: Failed with result 'protocol'.
```

The service is `Type=notify` and never notifies, so systemd reports a
protocol failure; the message is in `clickhouse-server.log`, not the
err.log. The packaged `config.xml` already sets `<partition_by>` for
`query_log`, `part_log` and `error_log`; a `config.d` override that adds
`<engine>` (Langfuse's docs give this shape as the "aggressive TTL" option)
merges *beside* that `partition_by` and is refused. Bound the tables with
`<ttl>event_date + INTERVAL 30 DAY DELETE</ttl>` instead. Keep `query_log`:
v4 reads `system.query_log*`; remove the six tables it never reads
(`trace_log`, `text_log`, `opentelemetry_span_log`,
`asynchronous_metric_log`, `metric_log`, `latency_log`).

## ClickHouse backup: `BACKUP_CREATED`, then `no objects under <stamp>/`

`BACKUP DATABASE default TO Disk('backups', '<stamp>/')` returned
`BACKUP_CREATED` with 270 files, and the bucket prefix held **128 objects
with random names** (`agp/jjppeptxopeoqjzmlhpvtwrwopqkb`, …) and nothing
under `<stamp>/`. A disk of `<type>s3</type>` stores objects under random
keys and keeps the path mapping in local metadata
(`/var/lib/clickhouse/disks/<name>/`), so only that node can ever read the
set back. A backup destination must be `<type>s3_plain</type>`, which
writes every file at its own path. Switching types on a live node: stop
the server, remove the old local metadata directory, start.

## Ansible: `Destination directory /etc/colors does not exist`

`ansible.builtin.copy` does not create parent directories; a play that
writes into a directory another play creates works only in the order the
plays happen to run. With `no_log: true` on the task the message is
censored and only the task name survives.

## Vultr: "already has an SSH key named <profile> that is not in this deployment's state" — right after a successful create

```
vultr already has an SSH key named langfuse-vultr (id ...) that is not in this deployment's state and matches ~/.ssh/langfuse-vultr.pub: a previous delete left it behind.
```

Not a leftover: the key was created by the previous converge and is in
state. ONCE's create matrix reads `:ssh_key_id` **with the underscore** from
the map the package's `state-fn` returns; a package that normalizes its tofu
outputs to kebab-case (`:ssh-key-id`) hides the key it owns and trips the
standard's never-adopt rule against itself. Return the keywordized params
untouched and normalize only the host list.

## Ansible: `failed at splitting arguments` on a shell task that looks fine

A shell block whose **comment** holds an odd number of apostrophes (`# Neon's
compute ...`) fails to load. Task names may carry apostrophes (YAML); shell
blocks may not. `ansible-playbook --syntax-check` on the rendered tree
catches it offline in a second; the neon-single-node catalogue already had
this entry and it was hit again.

## Redis: an unauthenticated `PING` "answered nothing"

A `/dev/tcp` probe reading the reply with `head -c 64` blocks forever: the
`-NOAUTH Authentication required.` reply is 33 bytes, `head` waits for 64,
the `timeout` kills the pipeline and the buffered bytes are lost. Read one
line (`read -r -t 4 line <&3`) instead. The negative gate was right; the
probe was wrong.

## The tool ceiling that kills a converge

Six machines take longer than a ten-minute agent tool timeout: converge 5 was
killed mid-Ansible with no error of its own. Run converges detached
(`setsid nohup ... &`) and watch the log; a killed Ansible run is idempotent
to resume.

## rclone: `NOTICE: Config file "/root/.config/rclone/rclone.conf" not found - using defaults`

Cosmetic, but it lands in gate output and reads like a fault. Set
`RCLONE_CONFIG=/dev/null` when every remote comes from the environment.

## `describe` says UNHEALTHY: "container langfuse-web restarted 13 times" — forty minutes after its last restart

Docker's `RestartCount` is cumulative for the container's life. A container
that looped during an early converge and has been healthy since — and was
never recreated, which is the idempotence working — carries that number
forever, and a monitor that thresholds the raw count accuses a healthy
host. Pair the count with `.State.StartedAt`: five or more restarts **and**
a start within the last thirty minutes means restarting now; the count
alone means history.
