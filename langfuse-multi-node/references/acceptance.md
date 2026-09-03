# Acceptance doctrine

Exit codes are not evidence; each gate asks the system what it actually
has. All of these ran against the live six-machine deployment; the
rehearsal ran there too and is repeatable with `./green rehearse` (or
`./red` and `./blue`, which render the same tree byte for byte). After the
red and blue ports landed, each colour ran one more idempotent converge
against the same deployment and passed every gate below.

## Server-side gates (every converge, from the app host)

- **The network says what the firewall says.** Raw TCP (`/dev/tcp`, never
  ping) to Neon 55433, Redis 6379, ClickHouse 8123 and 9000 — and a
  **refusal** on Keeper 9181. A Vultr firewall group filters the private
  interface too, and passes ICMP while dropping TCP, so ping proves nothing
  and an allow-only gate cannot tell a wide firewall from a right one.
- **Both databases answer `UTC`** (`SHOW timezone`, `SELECT timezone()`).
  Neon reports `GMT` until the database is altered.
- **The cluster is a cluster**: `clusterAllReplicas('default', system.one)`
  = 3 as the application user, Keeper root readable, and — inside the
  ClickHouse play — an authenticated `remote()` query from node 0 to node 1
  with the admin credential, plus `system.query_log` present after `SYSTEM
  FLUSH LOGS` and the backup disk registered in `system.disks`.
- **Health with the database flag** on web
  (`?failIfDatabaseUnavailable=true`) and **with the stuck-queue flag** on
  the worker (`?failIfQueueConsumptionStuck=true`).
- **One trace through the whole v4 path**: OTLP/JSON root span + generation
  with `x-langfuse-ingestion-version: 4` → 200; `POST /api/public/scores`
  → 200; the root and the generation readable through `GET
  /api/public/v2/observations?traceId=` within the timeout (observed: 4 s);
  the root carries the trace tags; ≥ 2 rows in `events_full` on node 0
  **and** on the last replica; the score row in `scores`; a **new** object
  under `<prefix>events/` beyond a pre-ingest `rclone lsf` baseline.
- **The media path, SDK-style**: `POST /api/public/media` (201) → `PUT`
  the presigned URL with `x-amz-checksum-sha256` → `PATCH` → `GET` → download
  → same sha256. The browser CORS preflight is reported as `WARN`, never
  gated: only an Admin R2 token can set it.
- **An encrypted row exists**: `PUT /api/public/llm-connections` upserts a
  dummy connection and it reads back with a display secret — the
  rehearsal later proves it decrypts on a fresh boot.
- **The negative space**: wrong secret key 401 and anonymous 401 **on a v2
  route** (the legacy routes are 404 for everyone), unauthenticated Redis
  `PING` → `NOAUTH`, wrong ClickHouse password 403, wrong Postgres password
  refused, and the write mode confirmed (`legacy batch 207, legacy trace
  read 404`).
- **Throughput**: 200 root spans named for the run, all returned by v2
  with `name=` + `isRootObservation=true` + `fromStartTime` within 120 s
  (observed with margin); host memory under 85 % after (observed 27 %).
- **Containers**: the compose project's container ids compared with the
  previous converge's — `ok` when nothing was recreated, `WARN` after a
  config change; never a failure.
- **Blast radius**: the backup credential is refused a listing of the
  live-data bucket (Neon host), and `system.query_log` on node 0 contains no
  occurrence of the backup secret (compared host-side, never by passing the
  secret into SQL).
- Only then the marker `<prefix>.colors-ready` lands, written with read-back
  (a 0-byte marker satisfies existence forever).

## Operator-side gate (every real create, from the workstation)

Through the **public name** over TLS and Cloudflare: health 200; the project
keys read over `ssh <profile>` (the app host); one OTLP root span in; v2
read-back within 120 s; wrong key 401; anonymous 401; then every one of the
seven SSH aliases answers `true`.

## The rehearsal (`./green rehearse`)

In the order recovery actually happens, across four hosts:

1. Fresh sets: ClickHouse first (node 0), then Postgres and media (Neon
   host) — so a Postgres dump exists that completed *after* the ClickHouse
   set. A ClickHouse set counts only when the bucket listing equals what
   `system.backups` reports for its id — `num_entries` + 1 (the `.backup`
   metadata file) objects and `compressed_size` bytes; `num_files` and
   `total_size` are the LOGICAL counts and do not match the disk; a media
   run records every archived object's MD5 and refuses to complete if any
   object the previous run archived is missing or changed — that is the
   only check that covers objects deleted from the live prefix since.
2. `clickhouse-restore-check --pair`: the newest completed ClickHouse set
   that has a later Postgres dump; `RESTORE DATABASE default AS
   restore_check FROM Disk('backups', …)`; the restored replicated tables
   register under Keeper paths distinct from the live database's (the
   `{uuid}` replica path plus RESTORE's new UUIDs).
3. `postgres-restore-check <paired stamp>`: checksum against the manifest,
   `CREATE DATABASE … OWNER langfuse`, `pg_restore` **as** `langfuse` from
   inside the compute container (Ubuntu's client is 16, compute is 17),
   every public table owned by the role.
   Any `pg_restore: error:` line fails the restore except `must be owner of
   extension` (the dump's `COMMENT ON EXTENSION plpgsql`).
4. `langfuse-rehearsal`: a second Compose project on loopback 3100 with the
   pinned web image, `DATABASE_URL` → the scratch database, `CLICKHOUSE_DB=
   restore_check`, `REDIS_KEY_PREFIX=restore:`, both auto-migrations off,
   the operator-held `ENCRYPTION_KEY`/`SALT`, a **fresh** `NEXTAUTH_SECRET`.
   Proven through the API: the live project keys authenticate (hashed keys +
   salt + Postgres), the smoke trace's root and generation read back
   (ClickHouse restore usable through the app), the seeded LLM connection
   returns its display secret (the row decrypts), and the smoke score is in
   `restore_check.scores`, read with the application user.
5. Drop both scratch databases.
6. **Replica loss**: stop ClickHouse on node 1, ingest and read back with it
   down, start it, `system.replication_queue` drains to 0 — the start is an
   Ansible `always`, so a failed probe cannot leave the replica down.
7. **Redis restart with a job queued**: stop the worker, enqueue a trace,
   restart Redis, start the worker (also in `always`), the trace becomes
   readable.
8. `<prefix>.colors-recovery-verified` with the two set stamps — a marker
   distinct from `.colors-ready`, because "the service answers" and "the
   service can be recovered" are different claims.

## What was deliberately not gated

- A coordinated (quiesced) snapshot across Postgres and ClickHouse. The
  pairing rule bounds the inconsistency instead: Postgres is always the
  newer snapshot.
- Browser media rendering (CORS is an operator step).
- Redis host loss recovery: queued jobs are lost and Langfuse documents no
  replay; the README says so.
- Any read from the `traces` / `observations` tables: on v4 they are empty
  by design.
