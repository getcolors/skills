# Failure catalogue

Every entry here was hit on a real converge. They are grouped by area; within
each group the ordering roughly follows the sequence a fresh build encounters
them.

**How to use this:** search for your symptom string first — most of these are
verbatim error text. If your symptom is "it says it worked but nothing
happened", read the whole file, because that describes about two thirds of them.

## Contents

- [ClickHouse and migrations](#clickhouse-and-migrations)
- [The ingestion chain](#the-ingestion-chain)
- [The web process](#the-web-process)
- [Celery and background jobs](#celery-and-background-jobs)
- [Configuration delivery](#configuration-delivery)
- [Credentials and access](#credentials-and-access)
- [Backups](#backups)
- [Host and provider](#host-and-provider)

---

## ClickHouse and migrations

### `There is no Zookeeper configuration in server config`

**Symptom.** The very first `CREATE TABLE` of `migrate_clickhouse` fails — the
migration history table itself. ClickHouse stays empty and the site serves 502s.

**Cause.** `migrate_clickhouse` calls `database.migrate(..., replicated=True)`
with no way to opt out, so every table PostHog creates is a
`ReplicatedMergeTree`, and those need coordination metadata.

**Fix.** Embedded ClickHouse Keeper — see the `keeper.xml` block the companion's `tools/ansible/main.yml` installs.
Upstream runs a separate ZooKeeper; a single node does not need one, Keeper runs
inside the same server on 9181 with a one-member raft config. A hand-written
`clusters.xml` supplies `remote_servers` for `ON CLUSTER` DDL, which is a
different mechanism and does **not** help here.

### `No macro hostClusterType in config`

**Symptom.** `migrate_clickhouse` creates tables successfully and *then* dies,
so it reads as a late fault rather than missing configuration.

**Cause.** `posthog/clickhouse/cluster.py` enumerates hosts with
`getMacro('hostClusterType')` and `getMacro('hostClusterRole')` and filters:

```
(role in requested_roles or ALL in requested_roles)
and (type == workload or workload == DEFAULT)
```

`ALL` is a wildcard on the *requesting* side, not the host side — a node
labelled `all` matches only callers passing `ALL`, while `data` matches both
`DATA` and `ALL`. Upstream ships these macros from its deployment tooling, not
from `docker/clickhouse/config.xml`, so a single node must declare them itself.

**Fix.** `hostClusterType: online`, `hostClusterRole: data`. Confirmed against
upstream's `docker/clickhouse/config.d/default.xml`.

### `Connection refused (127.0.0.1:9000)`

**Symptom.** Host selection finally works, and then every query to the cluster
is refused.

**Cause.** `remote_servers` advertised the replica as `127.0.0.1`. ClickHouse
republishes that through `system.clusters`, and the `web` container dials it —
where loopback is the `web` container itself.

**Fix.** Use the compose service name. ClickHouse resolves its own service name,
so `is_local` still selects this node. Keeper stays on loopback, because it runs
*inside* the ClickHouse server rather than across the network.

### `There is no named collection msk_cluster` / `warpstream_logs`

**Symptom.** `migrate_clickhouse` fails — the first time at table zero, later at
~267 tables as you add names one at a time.

**Cause.** PostHog's Kafka engine tables get their broker details from named
collections rather than inline settings. Two consequences: **a Kafka broker is
required for the schema to exist at all**, not merely for events to flow; and
every collection a migration names must resolve.

**Fix.** Declare all **eight** up front — see
the `named-collections.xml` block the companion's `tools/ansible/main.yml` installs. Only six are discoverable
from `posthog/settings/data_stores.py`; the rest are named directly by
migrations. Upstream's `docker/clickhouse/config.d/default.xml` is the
authoritative set. Adding them one failed converge at a time costs a full
migration run each.

### `TTL expression result column should have DateTime or Date type, but has DateTime64(3, 'UTC')`

**Symptom.** `migrate_clickhouse` clears the Kafka named collections and then
fails on a TTL expression.

**Cause.** PostHog's schema puts TTLs on `DateTime64` columns, which ClickHouse
24.8 rejects. The server was running a version the schema was never written for.

**Fix.** Track the `clickhouse-server` version upstream pins. See
`references/pins.md`.

### ClickHouse refuses connections from every other container

**Symptom.** ClickHouse is healthy and answers `clickhouse-client` *inside* its
own container. Every other service gets connection refused on 9000 or 8123.

**Cause.** The server is listening on loopback only. The images ship a
`listen_host` of `0.0.0.0` as one entry among several in their own
`config.d/`, and replacing the configuration wholesale — a single monolithic
`config.xml`, or bind-mounting over the whole `config.d` directory — silently
drops it along with everything else the image set.

**Fix.** Mount **individual files** into `/etc/clickhouse-server/config.d/`, as
the bundled assets do, so the image's own entries survive alongside yours. If
you must replace the configuration, declare `<listen_host>0.0.0.0</listen_host>`
yourself.

Note this is a different failure from the loopback `remote_servers` entry above,
and the two are easy to confuse: that one advertises a bad address to *other*
nodes through `system.clusters`, this one means the server never accepted the
connection at all.

### `Unknown table expression identifier 'system.crash_log'`

**Symptom.** 145 tables in, `migrate_clickhouse` fails on a system table.

**Cause.** ClickHouse creates system log tables on first write, so a freshly
started server has no `crash_log` — and a PostHog migration builds a metrics
view over it.

**Fix.** `SYSTEM FLUSH LOGS` before migrating. Verified: `EXISTS TABLE
system.crash_log` goes 0 → 1.

### `relation "django_content_type" already exists`

**Symptom.** Every create fails during migration.

**Cause.** Two migration runners on one schema. The application image migrates
on startup, and the playbook had started `web` (via a handler flush) before the
explicit `manage.py migrate` step. The loser dies.

**Fix.** Start only the datastores, migrate with the application down, then
converge the application containers. Drop the restart handler entirely — each
explicit `docker compose up -d` already applies the current compose file.

### `Some migrations are not cached and cannot be auto-rolled back` / `KeyError: ('social_django', 'code')`

**Symptom.** A fresh deployment restores the schema checkpoint and then
`migrate` stops on an interactive prompt at EOF.

**Cause.** The checkpoint was taken from a different commit than the image. A
checkpoint *behind* the image on one lineage heals forward, because `migrate`
applies the delta. From a *divergent* commit it plants migrations the image has
never heard of.

**Fix.** Stamp the checkpoint with its source commit
(`-- posthog-commit: <sha>`), compare against what the image reports at
`/code/commit.txt`, and restore only on an exact match — otherwise migrate from
zero, which is slow but correct. Restore only into a database with **no tables**,
always run `migrate` afterwards, and never `--fake`.

---

## The ingestion chain

The chain is **`capture → Kafka → plugin-server → ClickHouse`**. A break
anywhere still returns `2xx` to the client. Walk it in order.

### Events accepted with 200, nothing stored — `/capture/` returns 403

**Symptom.** Ingestion endpoints answer, but with CSRF 403 behind the scenes;
acceptance reports nothing captured.

**Cause.** Django resolves every ingestion path to its catch-all frontend view:
`/capture/`, `/e/`, `/i/v0/e/` all → `posthog.urls.home_with_region_redirect`.
**Event capture is no longer part of the Django application at all** — it is a
separate Rust service that writes to Kafka. Proxying those paths to the
application could never have worked.

**Fix.** Run the published `capture` image and route the ingestion paths to it
in the reverse proxy: `/capture /e /batch /i/* /track /engage /s` and their
subtrees. Everything else goes to the application.

### Events reach Kafka and stop there

**Symptom.** `events_plugin_ingestion` shows a rising high-watermark; ClickHouse
has no rows. Acceptance moves from "rejected" to "dropped" — accepted, never
stored.

**Cause.** Capture writes to `events_plugin_ingestion`; ClickHouse's Kafka engine
tables read `clickhouse_*` topics. **Nothing bridges the two** without the plugin
server, which ships as a separate Node image (`posthog/posthog-node`) and is not
part of `posthog/posthog`.

**Fix.** Run it, with `PLUGIN_SERVER_MODE: ingestion-v2-combined` — the mode that
consumes `events_plugin_ingestion` and produces `clickhouse_events_json`.

### Plugin server exits cleanly, over and over, consuming nothing

This one has **four** distinct causes, all presenting identically as a clean exit
and a restart loop. Work through them in order:

1. **`ENOENT: ../share/GeoLite2-City.mmdb`.** It loads a GeoIP database at
   startup; its own image ships none. The *application* image carries one at
   `/code/share`. Lift it across at converge time rather than committing 66MB,
   and mount it at every path the process may resolve that relative location to.
2. **Redis clients defaulting to loopback.** It opens several independent
   clients and **only the first reads `REDIS_URL`** — `cdp-redis`,
   `cdp-api-redis`, `logs-redis` and others fall back to `127.0.0.1:6379`, fail,
   and take the process down. Upstream runs more than one Redis, so each client
   has its own host setting; point them all at the one Redis here.
3. **No `PLUGIN_SERVER_MODE`.** It starts, finds no capabilities to run, and
   exits **zero**.
4. **`Error: Encryption keys are not set`** from `cdp/utils/jwt-utils.js`. At
   info level this appears as `Shutting down completed. Exiting...` — an ordinary
   clean shutdown with no error. Turn debug logging on to see it at all. Set
   `ENCRYPTION_SALT_KEYS`, shared with the application.

### `events` is empty but `sharded_events` has rows

**Symptom.** Indistinguishable from lost data: the UI shows nothing and
`SELECT count() FROM events` returns 0. But the rows are there.

**Cause.** `events` is a `Distributed` table over `sharded_events`. Reading it
fans out to whatever `system.clusters` advertises — so a `remote_servers` entry
pointing at `127.0.0.1` returns nothing from the calling container while the
underlying data is intact. HogQL queries the distributed table, which is why the
UI agrees with the wrong answer.

**Fix.** The `clusters.xml` service-name fix above. **Check both tables before
concluding ingestion is broken** — if `sharded_events` has rows, ingestion is
fine and this is a cluster configuration problem, which is a completely
different investigation.

### `column posthog_person.last_seen_at does not exist`

**Symptom.** The consumer dies on its first message; events reach Kafka and stop.

**Cause (first form).** The application and plugin server images were built from
*unrelated commits* and share a Postgres schema, so the Node process queried a
column the application's migrations never created. Both were floating tags.

**Cause (second form).** Even at one shared commit,
`posthog/posthog-node` queries the column and the application's migrations at
that commit do not create it.

**Fix.** Pin both images to **one commit** (see `references/pins.md`), and add
the column after migrations with `ADD COLUMN IF NOT EXISTS`, so an image that
grows it properly wins and the step becomes a no-op.

---

## The web process

### Container "running", nothing listening, proxy gets connection refused

Three separate causes, same presentation:

1. **`ValidationError: You must set OIDC_RSA_PRIVATE_KEY to use RSA algorithm` /
   `Error in setup_tasks_oauth, exiting.`** The container starts, fails OAuth
   setup and exits, repeatedly, while `docker compose ps` reports it running.
2. **`RuntimeError: Failed client connect: ... ("dns error", "failed to lookup
   address information")`.** Django connects to Temporal on startup through the
   Rust SDK bridge; the failure leaves the process **alive with nothing
   listening**. Temporal is a hard dependency, not a degraded feature.
3. **The default entrypoint never binds.** `./bin/docker` runs `./bin/migrate`
   first, which loops on `timeout 90 python manage.py schedule_temporal_workflows`.
   Run `./bin/docker-server` instead, with migrations as an explicit step.

### `config/dynamicconfig/development-sql.yaml: no such file or directory`

**Symptom.** Temporal sets up its schemas successfully and then refuses every
connection, so it never becomes healthy and compose refuses to start its
dependents.

**Cause.** That path is one upstream mounts from its own checkout; the
`auto-setup` image ships only `docker.yaml`. A missing dynamic config stops the
server booting.

**Fix.** `DYNAMIC_CONFIG_FILE_PATH: config/dynamicconfig/docker.yaml`. Point it
at the Postgres already present; Elasticsearch is upstream's visibility store
and is not required.

### Health gate expires against a stack that was about to be fine

**Symptom.** The converge fails after five minutes; measured immediately
afterwards, `/_health/` answers 200 in 1.7 seconds with stable workers.

**Cause.** NGINX Unit boots four Django workers, each loading the whole
application. First start is well over five minutes.

**Fix.** Allow twenty minutes. The gate still fails loudly if the application
never serves — it just stops calling a slow boot a failure.

### Every non-exempt path 301-redirects to itself

**Symptom.** `/_health/` returns 200 and the site looks fine, while capture loops
forever.

**Cause.** Behind a TLS-terminating proxy Django cannot see that the request
arrived over TLS and redirects to the URL it is already on. `/_health/` is
exempt from that redirect, which is exactly why the site looks healthy while
ingestion is impossible.

**Fix.** `IS_BEHIND_PROXY` and `TRUST_ALL_PROXIES`.

### `bin/migrate-check` never returns

**Symptom.** The web process never binds; the health gate expires against a
server that is not coming.

**Cause.** The server entrypoint runs `bin/migrate-check`, whose third command is
`run_async_migrations --check` — it needs the async-migrations setup a reduced
deployment skips.

**Fix.** `POSTHOG_SKIP_MIGRATION_CHECKS: "1"`. Note this is only safe **because**
the playbook runs `migrate` and `migrate_clickhouse` itself and fails the
converge if either fails — a stronger guarantee than the in-container check. Set
without that, the flag hides an empty ClickHouse, which is how it was misused
earlier in this package's history.

---

## Celery and background jobs

### `ImproperlyConfigured: Migration 0007_persons_and_groups_on_events_backfill is required for PostHog versions above 1.43.0`

**Symptom.** Celery cannot start at all — 74 restarts — behind an otherwise
green deployment. Acceptance passes, because the ingestion path never touches
Celery.

**Cause.** Required async migrations block Celery, and async migrations are
normally run from the UI or **by Celery itself**. A fresh install cannot break
the cycle unaided.

**Fix.** Run the ones upstream classifies as no-ops
(`run_async_migrations --complete-noop-migrations`), then complete the remaining
backfills **only where ClickHouse holds zero events** — over zero rows a backfill
is provably a no-op. Where data exists, skip it and run them from the UI.

### Plugin server reported failing while perfectly healthy

**Symptom.** PostHog's own setup UI reports the plugin server as failing; its
`/_health` answers 200 and it is consuming the ingestion topic.

**Cause.** Django probes it through `CDP_API_URL`, which defaults to a Kubernetes
service name that resolves nowhere in a single-node deployment.

**Fix.** Point it at the plugin server this stack actually runs.

---

## Configuration delivery

### The single-file bind-mount inode trap

**This one bit twice, in two different services.** It is the most valuable entry
in this file.

**Symptom.** The config on the host is correct. The container behaves as though
it is not. Ansible reports `ok=22 changed=0 skipped=1` while the failure repeats
for the third time.

**Cause.** A single-file bind mount is bound to the **inode** Docker resolved
when the container started. `ansible.builtin.copy` replaces files by writing a
temporary file and renaming it over the target — a new inode. The container goes
on serving the old file forever, while the host path shows the new content.

**Fix, part one.** Recreate the container so the mount re-resolves.

**Fix, part two — and this is the part that is easy to miss.** Do *not* key the
recreate on this run's change flags. On the next converge the files are already
correct, `copy` reports no change, the recreate is skipped, and the container
carries on serving what it started with. **Ask the server what it actually
loaded:**

- ClickHouse: `SELECT count() FROM system.macros WHERE macro = 'hostClusterType'`
  plus `system.named_collections` — if the macro is absent, the running container
  predates the current configuration, whatever changed this run.
- Caddy: compare `sha256sum /etc/caddy/Caddyfile` *inside the container* against
  the file on disk.

Convergent rather than change-triggered, so it also heals a host already in the
broken state.

### Capture routing present on disk, ignored in practice

**Symptom.** The capture service runs and answers 200 on its own port, the
ingestion routes are in the Caddyfile on the host — and every public request
still reaches the application.

**Cause.** The inode trap above, in Caddy.

**Fix.** As above: checksum comparison against what Caddy is serving.

### An unquoted `{{ ... }}` makes the compose file unparseable

**Symptom.** Docker discovers it on the host, after a successful-looking render.

**Cause.** A multi-line PEM rendered through `to_json` at the start of a YAML
value reads as a **flow mapping**.

**Fix.** Use a block scalar with `indent()`. Add a test that parses the rendered
template and counts its services — this is cheap and catches the whole class.

### Three copies of the application environment drift

**Fix.** One YAML anchor (`x-posthog-environment: &posthog-environment`) merged
into `web`, `worker` and `plugins`. They had already drifted once; a merge key
cannot.

---

## Credentials and access

### A committed `SECRET_KEY`

**Cause.** `SECRET_KEY` defaulted to a constant in a public repository, and the
database password was a fixed `posthog:posthog`. Anyone could forge session
cookies and password-reset tokens against a deployment that never overrode it.

**Fix.** Both from the environment at converge time. Ship the compose file with
a **templating** module at mode `0600` (a plain copy does not render), and
percent-encode the password inside `DATABASE_URL`. Make them required so a real
create fails **before any provider call** rather than falling back to a published
value. Verify the rendered artefact contains neither.

### The invite wall — a UI its owner cannot log into

**Symptom.** A fresh deployment serves a working UI that nobody can get into.
`_preflight` reports `can_create_org: false` and the signup page shows an invite
wall.

**Cause.** PostHog's hosted realm only lets the **first** user create an
organization. Anything that creates one first — including an acceptance check
asking for a project — closes signup permanently.

**Fix.** The deployment owns the account. the companion's `tools/ansible/owner.py` handles all
three states a converge can find (empty instance, existing organization,
existing account), so it is idempotent and rotates the password every run.

---

## Backups

### A ClickHouse archive that cannot be restored

**Symptom.** None, until you try to restore. That is the point.

**Cause.** `tar` of `/var/lib/clickhouse/{metadata,data}` from inside the running
container races the server's merges — parts vanish mid-read. Worse, when `tar`
exited non-zero a host-side fallback silently overwrote the archive with a
second torn copy.

**Fix.** ClickHouse's own `BACKUP DATABASE ... TO File(...)`, into a path under
the server's `backups.allowed_path` that sits on the bind mount and is therefore
reachable from the host. **No fallback** — a failed ClickHouse backup must fail
the whole run.

---

## Host and provider

### Every create fails on the first task with a 404

**Cause.** A fresh droplet ships apt lists old enough to name package versions
the archive has already superseded, and with `cache_valid_time` set Ansible
skips the update and goes straight to a 404.

**Fix.** Always refresh apt lists; no `cache_valid_time`.

### Containers cannot reach each other on Ubuntu 24.04

**Symptom.** Docker starts, containers start, and networking between them does
not work — or the daemon fails to set up its own rules at all.

**Cause.** Ubuntu 24.04 defaults to the `nftables` iptables backend, and Docker
expects the legacy one.

**Fix.** Point both alternatives at legacy before installing or starting Docker:

```sh
update-alternatives --set iptables  /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

This has not been needed on every image — the getcolors package converges on
`ubuntu-24-04-x64` without it — so treat it as the first thing to check when
container-to-container networking misbehaves on a fresh 24.04 host rather than
as an unconditional step.

### Ansible pointed at TEST-NET

**Symptom.** The failure looks like an unreachable host rather than a missing
provider output.

**Cause.** The converge merged fallback parameters and then the compute outputs,
so a missing address left the documentation address `192.0.2.10` — what the
credential-free build and dry-run paths render — in place.

**Fix.** Require the address on a real event and fail with a message that says
exactly that.

### A successful request leaves no trace

**Symptom.** Ingestion is undebuggable: no request-level evidence that an event
ever reached capture.

**Cause.** Access logging is off by default in Caddy, so only errors and TLS
events were recorded.

**Fix.** Turn it on to stdout as JSON, and **bound it** in the container's
logging options — an ingestion endpoint writes a line per request and the default
`json-file` driver never rotates. Behind Cloudflare, also declare
`trusted_proxies`, or every request is attributed to the edge rather than the
visitor.
