# Pins

## The verified-good set

Running together on six Vultr instances in `ams` (Ubuntu 24.04, os id
2284) with every acceptance gate passing, plus the restore-and-boot
rehearsal and the two drills. **Verified 2026-09-03.**

| Component | Pin |
|---|---|
| langfuse-web | `docker.langfuse.com/langfuse/langfuse:4.27.0@sha256:c9e2cab8469a5d7353e86a3252b02c52ac94ef31288ce2639ee01aabf5e4222b` |
| langfuse-worker | `docker.langfuse.com/langfuse/langfuse-worker:4.27.0@sha256:091a85c3c54bf5fff7cc0073a7f35a52861cc0e30d33dd05569fe3ed66b15d8d` |
| ClickHouse (apt, three replicas + Keeper) | `26.3.29.7` from `packages.clickhouse.com/deb stable` |
| Redis | `docker.io/library/redis:7.2.16@sha256:74566c6910d13ae61e7ce73ebd3127438a1fe805b309b097c323142719ec8a5b` |
| Caddy | `docker.io/library/caddy:2.11.4@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d` |
| Neon storage image | `ghcr.io/neondatabase/neon:release-9129@sha256:166022a72bf9983eba96d061d794f4740edbd4c3301e66202c1180acce9a323c` |
| Neon compute image (Postgres 17) | `ghcr.io/neondatabase/compute-node-v17:release-compute-9073@sha256:ed6a613231d7026b4df8b00563444b9f33745370a3b3f0a2183e723f460ba974` |
| `getcolors/neon` templates | `87c009549a928fdf1f9dc135f9740c3baa5782d7` |
| `getcolors/langfuse` (companion, final pin) | `e7a18678d3b7a5be23cd6f701927794514e7efe6` |
| Plans | Neon `vc2-4c-8gb`, Redis `vc2-1c-2gb`, ClickHouse ×3 `vc2-4c-8gb`, app `vc2-4c-8gb` |
| host packages | Ubuntu 24.04 apt: `docker.io`, `docker-compose-v2`, `postgresql-client` (16), `rclone` (1.60.1), `ufw`, `jq`, `openssl`, `python3` |

## The rules that generated it

### Langfuse: the v4 default write mode is the contract

`docker.langfuse.com` fronts Docker Hub (`langfuse/langfuse`); the digests
resolve identically from both. Web and worker are one release train — move
them together. A **fresh v4 deployment runs `LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only`**,
which decides the shape of every gate (see the catalogue): the legacy batch
endpoint rejects events, the legacy trace reads are 404, and the data lives
in `events_full`/`events_core`. Any gate written from v3 knowledge fails
against v4 while the deployment is healthy.

### ClickHouse: v4 needs 25.12, the apt repository serves exact versions

Langfuse v4 requires ClickHouse ≥ 25.12 (26.4 recommended) for lightweight
updates, the JSON type and full-text search. `packages.clickhouse.com/deb`
serves both `stable` and `lts`; `26.3.29.7` is the current LTS train and
installs by exact version (`clickhouse-server=26.3.29.7`). The repository
dropping a version fails the converge loudly rather than drifting.

### Redis 7.2, `noeviction`, AOF

Langfuse requires ≥ 7 with `maxmemory-policy noeviction` and recommends 7.2
for v4. The AOF on a named volume is what makes a restart keep queued jobs
(drilled); a lost host loses the queue, and Langfuse documents no replay.

### Neon: the last deliberate release pairing, from the pin

The storage tier is `getcolors/neon` at the commit `n8n-vultr` verified live
on 2026-09-01; the image pairing and its reasoning are in the
`neon-single-node` Context Skill. Bump the neon pin only through that
package's own tests and goldens.

### Retest conditions

- **Any Langfuse bump**: re-verify the write mode default and the four
  facts the gates depend on — OTLP at `/api/public/otel/v1/traces` with
  `x-langfuse-ingestion-version: 4`, `GET /api/public/v2/observations`
  parameters, `POST /api/public/media` answering **201**, `POST
  /api/public/scores` still accepted — and the Prisma `P3005` behaviour on a
  non-empty schema.
- **Any ClickHouse bump**: re-verify that `<ttl>` on the system log tables
  still merges beside the base `partition_by`, that `s3_plain` is still the
  path-preserving disk type for `BACKUP TO Disk`, and that `RESTORE ... AS`
  still assigns fresh UUIDs (the `{uuid}` replica path is what keeps a
  restore collision-free).
- **Any Neon bump**: the `neon-single-node` retest conditions, plus the
  `colors_smoke` table its play creates in the application database.
- **rclone newer than ~1.64**: the `no_check_bucket`/`no_head`/no-`rcat`
  rules may lapse; retest before dropping them.
