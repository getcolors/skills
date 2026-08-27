---
name: posthog-single-node
description: Everything needed to stand up a working self-hosted single-node PostHog on one server - the ten-container topology, the ClickHouse Keeper/macros/named-collections configuration PostHog's migrations require, the capture and plugin-server ingestion chain, the converge ordering, and a catalogue of ~30 failures that each look like success. Use this whenever the user mentions self-hosting, deploying, provisioning, upgrading, or debugging PostHog, or is working on a PostHog docker-compose, Ansible playbook, ClickHouse schema, migrate_clickhouse run, or event-ingestion problem - even if they do not say "single-node" and even if they think their problem is small. Also use it when someone reports that PostHog accepts events but stores none, that a container "runs" but serves nothing, or that Celery will not start.
---

# Single-node PostHog

PostHog does not have a working small deployment story. Upstream's own
single-server topology is roughly **35 services**; their "hobby" compose is
tuned for a laptop demo and does not survive contact with a real host. What
follows is a **ten-container reduction that has been verified end to end** on a
`s-4vcpu-8gb` droplet: capture returns 200, the row appears in ClickHouse within
five seconds with the right team, and `execute_hogql_query` — the same path the
UI queries — returns it.

Every fact here was paid for by a failed converge. The working files live in
the [`getcolors/posthog`](https://github.com/getcolors/posthog) Package Skill
under `src/resources/io/github/getcolors/posthog/tools/` — start from those
rather than deriving them again; this skill carries the *why* (see "The
reference implementation" below).

## The thing to internalize first

**PostHog fails silently, at every layer.** This is not a colourful way of
saying it has bugs; it is the single most useful prediction you can carry into
this work. Across ~50 commits of getting this stack up, nearly every failure
took the same shape: a component reported healthy, `docker compose ps` said
running, exit codes were zero — and nothing worked.

- The web container starts, fails OAuth setup, exits, restarts, forever, while
  `docker compose ps` reports it running.
- The plugin server throws `Encryption keys are not set` and logs, at info
  level, `Shutting down completed. Exiting...` — indistinguishable from a clean
  shutdown. Ten restarts look like a process with nothing to do.
- With no `PLUGIN_SERVER_MODE` it starts, finds no capabilities, and exits
  **zero**.
- Django's Temporal client fails to connect and leaves the process **alive with
  nothing listening**.
- `/capture/` returns a `2xx` and the event is never stored.
- Celery restarts 74 times behind a green health check, because the ingestion
  path never touches Celery.
- Ansible reports `ok=22 changed=0` while a container serves configuration from
  an inode that no longer exists on disk.

The practical consequence: **never accept a status code, a change flag, or a
container state as evidence.** Ask the component what it actually loaded. That
principle is what the acceptance step in `references/acceptance.md` is built
around, and it is why the playbook queries `system.macros` instead of trusting
Ansible's `changed` flags.

## The ten containers, and why none is optional

Read the companion's `tools/ansible/compose.yml` — it is the working file,
with the reasoning kept inline on each service. The short version:

| Service | Image | Why it cannot be dropped |
|---|---|---|
| `db` | `postgres:17-alpine` | Application state; also Temporal's persistence store |
| `redis` | `redis:7.2-alpine` | Celery broker — **not** a cache (see below) |
| `kafka` | `redpandadata/redpanda` | PostHog's ClickHouse migrations create Kafka **engine tables**; without a broker the *schema cannot be created* |
| `clickhouse` | `clickhouse/clickhouse-server` | Event store, with **embedded Keeper** |
| `temporal` | `temporalio/auto-setup` | Django connects on startup via the Rust SDK bridge; failure means the web process never binds |
| `capture` | `ghcr.io/posthog/posthog/capture` | Event ingestion is **not part of Django** — `/capture/` hits the catch-all view and 403s on CSRF |
| `plugins` | `posthog/posthog-node` | The **only** bridge from `events_plugin_ingestion` to the `clickhouse_*` topics ClickHouse subscribes to |
| `web` | `posthog/posthog` | The application, run as `./bin/docker-server` |
| `worker` | `posthog/posthog` | Celery, `./bin/docker-worker-celery --with-scheduler` |
| `caddy` | `caddy` | TLS termination and the capture/application routing split |

Two topology facts that are easy to get wrong and expensive to diagnose:

**The ingestion chain is `capture → Kafka → plugin-server → ClickHouse`.** Four
processes, and a break anywhere returns `200` to the client. If events are
accepted but absent, walk that chain rather than looking at Django.

**Redis is the Celery broker.** PostHog's hobby compose caps it at 200mb with
`allkeys-lru`, which silently discards queued ingestion tasks under pressure.
Use `noeviction` with real headroom.

Elasticsearch, object storage, browserless and upstream's seven ingestion
workers are all genuinely optional and are left out deliberately.

## ClickHouse is where most of the pain lives

Three config files must be mounted into `/etc/clickhouse-server/config.d/`.
The companion's converge playbook (`tools/ansible/main.yml`) writes each one
inline, with its reasoning in the task that installs it:

- **`keeper.xml`** — embedded Keeper plus the `hostClusterType`/`hostClusterRole`
  macros. `migrate_clickhouse` passes `replicated=True` unconditionally, so every
  table is a `ReplicatedMergeTree` and needs coordination metadata; and
  `posthog/clickhouse/cluster.py` selects hosts by those macros, which upstream
  ships from its deployment tooling rather than its `config.xml`.
- **`clusters.xml`** — nine `remote_servers` entries, all pointing at the
  **compose service name**. Writing `127.0.0.1` here gets republished through
  `system.clusters` and other containers then dial their own loopback.
- **`named-collections.xml`** — all **eight** Kafka named collections. Only six
  are discoverable from settings; the other two are named directly by
  migrations, and each missing one costs a full `migrate_clickhouse` run to find.

Beyond those files:

- **Run the ClickHouse version upstream pins.** PostHog puts TTLs on
  `DateTime64` columns, which older servers reject outright
  (`TTL expression result column should have DateTime or Date type`).
- **`SYSTEM FLUSH LOGS` before migrating.** System log tables are created on
  first write, so a fresh server has no `system.crash_log` — and a PostHog
  migration builds a metrics view over it.

## Converge order that works

The companion's `tools/ansible/main.yml` is the whole playbook. The ordering
is load-bearing; these are the constraints behind it:

1. **Start the datastores alone** (`db redis kafka clickhouse`). The application
   image migrates on startup, so bringing `web` up before the explicit migration
   puts two runners on one schema and the loser dies on
   `relation "django_content_type" already exists`.
2. **Recreate ClickHouse if the server has not loaded the current config** —
   keyed on `system.macros`, *not* on Ansible's change flags. See the inode trap
   in `references/failure-catalogue.md`; this one bit twice, in two services.
3. **`SYSTEM FLUSH LOGS`**, then wait for Postgres.
4. **Lift the GeoIP database out of the application image.** The plugin server
   loads one at startup and dies without it; its own image does not ship one.
5. **Restore the schema checkpoint only into an empty database, and only when
   its stamped commit matches the image's** `/code/commit.txt`. Replaying
   migrations from zero takes **over an hour** on this hardware, so this is the
   single biggest time saver — but a checkpoint from a divergent commit plants
   orphaned migrations and `migrate` then stops with a `KeyError`. Never `--fake`.
6. **`migrate` then `migrate_clickhouse`**, with the application still down.
7. **Complete the no-op async migrations, and the backfills only where ClickHouse
   holds zero events.** Required async migrations block Celery from starting, and
   Celery is normally what runs them — a fresh install cannot break that cycle
   unaided. Over zero rows a backfill is provably a no-op.
8. **Bring the application up**, recreate Caddy if it is serving a stale
   Caddyfile checksum, then wait on `/_health/` with a **twenty-minute** budget:
   NGINX Unit boots four Django workers each loading the whole application.

## Credentials

None of these have defaults, and the stack must refuse to converge without them
rather than falling back to a published value:

| Variable | Why |
|---|---|
| `POSTHOG_SECRET_KEY` | Django signing key — a committed constant lets anyone forge session cookies |
| `POSTHOG_POSTGRES_PASSWORD` | Percent-encode it inside `DATABASE_URL` |
| `POSTHOG_OIDC_RSA_PRIVATE_KEY` | OAuth setup aborts the web process without it; render as a **block scalar**, not `to_json` |
| `POSTHOG_ENCRYPTION_SALT_KEYS` | Shared by application and plugin server; missing means silent no ingestion |
| `POSTHOG_ADMIN_PASSWORD` | Owner account — see below |

**Provision the owner account yourself** (the companion's
`tools/ansible/owner.py`). PostHog's
hosted realm only lets the *first* user create an organization, so once anything
creates one — including an acceptance check asking for a project — the signup
page shows an invite wall and nobody can get in at all. The script is idempotent
across the three states a converge can find.

## Reference material

Read these as needed rather than up front:

- **`references/failure-catalogue.md`** — ~30 failures as
  *symptom → cause → fix*, in the order they were hit. Go here first when
  something is broken; the symptom you are looking at is probably in it verbatim.
- **`references/pins.md`** — the verified-good image set with the date, plus the
  constraints that generated it, so you can pick a new set when these age out.
- **`references/acceptance.md`** — what to verify after a converge, and why the
  obvious checks pass against a broken deployment.

## Check your rendered configuration before it reaches a host

Four properties are silent on the server when wrong, so verify them on your
**rendered** files rather than waiting for the symptom (each has a full entry
in `references/failure-catalogue.md`):

- every ClickHouse config XML actually parses — an unparseable file makes
  ClickHouse start *without* the settings it describes;
- all **eight** Kafka named collections are present — a missing one surfaces
  hundreds of tables into a migration;
- no `remote_servers` replica host is a loopback address — `127.0.0.1` only
  bites when another container dials it;
- the application and plugin-server images pin the **same** commit — a
  mismatch only appears when the consumer hits its first message.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/posthog`](https://github.com/getcolors/posthog) Package Skill
under `src/resources/io/github/getcolors/posthog/tools/` — the converge
playbook `ansible/main.yml` (which also writes the three
`clickhouse-config.d` files inline), `ansible/compose.yml` with the
ten services, the Caddyfile, the backup script, `ansible/owner.py`, the
stamped `ansible/checkpoint.sql`, and the `dns/` and `infrastructure/`
OpenTofu — covered by that repo's tests and golden fixtures and consumed by
the `posthog-digitalocean` deployment. This skill deliberately does **not**
carry copies of them: a second, untested copy drifts, and this workspace has
a documented history of exactly that failure. Read the files there; read *why
they are shaped that way* here. Outside the Colors ecosystem the topology and
the traps transfer wholesale — only the OpenTofu/Ansible packaging is local.

**On the templating delimiters.** In those files `<{ key }>` is substituted
at build time by the green package's scaffold and `{{ ... }}` survives into
Ansible. If you are reusing them outside that context, `<{ ... }>` are your
substitution points. Keep the distinction deliberate: an unquoted `{{ ... }}`
at the start of a YAML value reads as a flow mapping and makes the file
unparseable — a failure Docker only discovers on the host.

**On `checkpoint.sql`.** It is stamped with the commit it was taken from
(`82ea6681…`, 309 tables, 1337 applied migrations). It is plain SQL carrying the
schema and the `django_migrations` rows and nothing else. It is worth an hour
per fresh deployment, but **only for its own commit** — regenerate it when the
pin moves:

```sh
docker compose exec -T db pg_dump -U posthog --schema-only posthog > checkpoint.sql
docker compose exec -T db pg_dump -U posthog --data-only -t django_migrations posthog >> checkpoint.sql
# then prepend:  -- posthog-commit: <the commit /code/commit.txt reports>
```
