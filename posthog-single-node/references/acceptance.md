# Verifying a converge

The governing rule: **every claim the check reports must be one it actually
checked.** PostHog is unusually good at looking healthy, so the obvious probes
all pass against a stack that stores nothing.

## Checks that do not work, and why

These were all tried. Each one passed against a deployment that was broken.

| Check | Why it passes anyway |
|---|---|
| `pg_isready` on the `db` container | Reports PostgreSQL is up. The web service can be crash-looping or unmigrated. |
| `docker compose ps` showing `running` | The web process stays alive with nothing listening when the Temporal connect fails; the plugin server restart-loops on clean exits. |
| `curl -k https://host/_health/` | `-k` accepts a broken certificate. And `/_health/` is **exempt from the TLS redirect**, so it answers 200 while every ingestion path 301-loops. |
| A `2xx` from `/capture/` | Capture returning 200 says the event reached Kafka. Nothing about whether it was ever stored. |
| `systemctl start posthog-backup.service` succeeding | Says systemd started something. Not that an archive exists, is non-empty, or is restorable. |
| Ansible's `changed` flags | A container can serve a config from an inode that no longer exists on disk while every task reports `ok`. |
| The ingestion path being green | Celery can be dead — 74 restarts — behind all of it. Ingestion never touches Celery. |

## What to check instead

### TLS, without `-k`

Poll `https://<host>/_health/` with certificate verification on. Allow twenty
minutes: NGINX Unit boots four Django workers, each loading the whole
application.

### A real event, read back out of ClickHouse

1. Read a project API token: `select api_token from posthog_team order by id limit 1`.
   No project means the verdict is *not configured* — not a claim of capture.
2. Count events first, `POST` a synthetic event to `/capture/`, then **poll**
   until the count rises. Ingestion is asynchronous; sampling once is a race.
3. Resolve the events table from `system.tables` rather than hardcoding a
   database name PostHog's migrations own:
   ```sql
   SELECT database || '.' || name FROM system.tables
   WHERE name = 'events' AND database NOT IN ('system')
   ORDER BY database LIMIT 1
   ```

Distinguish the outcomes, because they point at different parts of the chain:

| Verdict | Meaning | Where to look |
|---|---|---|
| `ingested` | count rose | — |
| `dropped` | `2xx`, no stored row | Kafka → plugin-server → ClickHouse |
| `rejected` | non-2xx | capture service, or proxy routing |
| `unreachable` | no response | Caddy, DNS, TLS |
| `not-configured` | no project exists | owner/organization provisioning |

The `dropped` verdict is the one this stack produced most often, and it is
invisible to any status-code check.

### Background jobs — ask PostHog, do not infer

One call inside the `web` container answers both questions:

```python
from posthog.utils import is_celery_alive
from posthog.models.async_migration import AsyncMigration
print('celery=%s pending=%d' % (is_celery_alive(),
      AsyncMigration.objects.exclude(status=2).count()))
```

Distinguish `celery-down` from `migrations-pending` from `unreachable`, so a
failure says which. A pending required migration stops the worker starting at
all, so these two are causally linked but need different fixes.

### Backups — confirm the object, not the unit

Trigger the backup, then list the profile prefix in object storage and require a
non-empty object **newer than this run**. Compare `ModTime` against a timestamp
captured before the trigger.

### Optional: cross-check against PostHog's own setup page

It found a failure the ingestion checks could not — the dead Celery worker — and
also produced a false positive (the plugin server reported failing while healthy,
because `CDP_API_URL` defaults to a Kubernetes service name). Useful as a second
opinion, not as the gate.

## Structuring the check

Keep the verdict logic pure and unit-test it — `ingestion-verdict`,
`background-verdict`, backup freshness. The I/O is untestable without a live
host, but the decision rules are exactly where mistakes hide. One real example
worth avoiding: an early version computed a capture result and then never
referenced it in the branch that reported success, so it announced `:capture :ok`
unconditionally — including when `/capture/` rejected the request.
