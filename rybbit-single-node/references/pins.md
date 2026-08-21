# Image pins

## The verified-good set

These were running together on a `s-2vcpu-4gb` DigitalOcean droplet with events
flowing end to end, backups uploading, and acceptance passing.
**Verified 2026-08-17.**

| Service | Image |
|---|---|
| `postgres` | `postgres:17-alpine` |
| `clickhouse` | `clickhouse/clickhouse-server:24.8-alpine` |
| `redis` | `redis:8.6.4-alpine` |
| `backend` | `ghcr.io/rybbit-io/rybbit-backend@sha256:f729f42575bf018ff97e9f36d49200665b99003a14868acbe56a9b32a9ed6ac7` |
| `client` | `ghcr.io/rybbit-io/rybbit-client@sha256:f384c1f73a0c2fc0794526908a1fdb2ba410a5cdb3f105487af70f067c8f103a` |
| `caddy` | `caddy:2.11.4` |

The two digests are what `:latest` resolved to on 2026-08-17.

## The rules that generated it

Start here when the set above has aged out. These constraints are what matter;
the specific versions are just their current solution.

### Pin the application images by digest

`rybbit-backend` and `rybbit-client` publish `:latest`, which moves under the
deployment — a converge can deploy something different with no change on your
side, and no record of what changed.

```sh
docker buildx imagetools inspect ghcr.io/rybbit-io/rybbit-backend:latest \
  --format '{{.Manifest.Digest}}'
```

Record the date you resolved it. A digest is the only pin that cannot move, so
whatever validates your desired state must accept the digest forms —
`name@sha256:…` and `name:tag@sha256:…` — or the strongest available pin is not
expressible.

### Move the backend and the client together

They are two halves of one application sharing a Postgres schema. The sibling
PostHog deployment is the cautionary case: an application and a plugin server
built from different commits, with the consumer dying on a column the other
image's migrations had never created, and nothing on the operator's side to
explain it. Resolve both digests in the same change.

### ClickHouse must support what the schema needs, under the current name

Rybbit's schema uses ClickHouse's JSON type. The setting that enables it has
already been renamed once, and **a name the server does not recognise is ignored
rather than rejected** — so the profile looks installed and the schema still
will not build.

| ClickHouse | Setting |
|---|---|
| 24.8 (the verified pin) | `allow_experimental_json_type` + `allow_experimental_object_type` |
| 25.x and later (current upstream) | `enable_json_type`; the object-type setting no longer exists |

Move `clickhouse_json_settings` in `group_vars/all.yml` in the same commit as
`clickhouse_image`, and confirm on the host rather than assuming:

```sql
SELECT name, value FROM system.settings WHERE name LIKE '%json_type%'
```

Note that upstream has moved well past 24.8 — its compose currently ships
ClickHouse 26.x. The pin here is what this deployment verified, not what
upstream runs; if you follow upstream's version you must also follow its setting
name.

### The datastores are ordinary

Postgres, Redis and Caddy carry no Rybbit-specific constraint. Pin them to
explicit tags for reproducibility and move them on their own schedule.

## When you move a pin

1. Re-resolve **both** application digests, in one change.
2. Check the ClickHouse settings still exist under those names if you are moving
   ClickHouse.
3. Converge, then run `scripts/acceptance.sh` end to end. Read
   `acceptance.md` first: several obvious checks pass against a broken
   deployment, and a moved pin is exactly when you need the ones that do not.
4. Trigger a backup and confirm a fresh object in the bucket. A schema change
   can break the dump path without touching ingestion.

## Sizing

Measured on the running stack rather than estimated: six containers held about
**1.0GB resident** — ClickHouse 457MB, backend 443MB, everything else under 70MB
— with load average 0.7 across four vCPUs and 6.2GB of disk in use.

`s-2vcpu-4gb` is ample for a small-team deployment. Resist sizing up "to be
safe": on DigitalOcean the disk that comes with a larger plan is what makes the
plan impossible to leave later. See `providers.md`.
