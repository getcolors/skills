# Verifying a converge

The governing rule: **every claim the check reports must be one it actually
checked.**

Rybbit is not pathological the way PostHog is — a healthy-looking Rybbit stack
usually is healthy. But the checks that matter are still the ones that can fail,
and the obvious ones cannot. Each entry below was tried on this deployment and
passed against something broken.

## Checks that do not work, and why

| Check | Why it passes anyway |
|---|---|
| `docker compose ps` showing healthy | Says the process is alive and its own probe answers. Says nothing about whether an event posted from outside is stored. |
| `curl -k https://host/api/health` | `-k` accepts a broken or expired certificate, which is one of the few things that will actually break your ingestion from real browsers. |
| A `2xx` from `/api/track` | The endpoint accepted the request. Whether a row landed in ClickHouse is a separate question with a separate answer. |
| A non-2xx from `/api/track` | Also inconclusive on its own: a malformed *synthetic* payload fails identically to a broken pipeline. Distinguish them. |
| `systemctl start rybbit-backup.service` succeeding | systemd started something. Not that an archive exists, is non-empty, is new, or restores. |
| `systemctl is-active rybbit-backup.timer` | The timer is scheduled. It has never been established that a run produces anything. |
| Ansible's `changed` flags | A container can serve configuration from an inode that no longer exists on disk while every task reports `ok`. |
| The value in `stack.env` on the host | `env_file` is read at container creation. The file and the running process disagree until you recreate. |
| The check "passing" | If it reports `not-configured` when a precondition is absent, and that precondition is usually absent, it has been skipping itself. |

## What to check instead

### TLS, without `-k`

Poll `https://<host>/api/health` with certificate verification on. Certificate
provisioning is the slow part of a first converge; allow a few minutes rather
than failing at the first refusal.

Check the backend's health from *inside* the container as a separate step. When
the two disagree, the fault is in Caddy, DNS or TLS rather than the application
— and that distinction is otherwise a guess.

### A real event, read back out of ClickHouse

1. **Resolve the events table** from `system.tables` rather than hardcoding a
   database name Rybbit's migrations own:
   ```sql
   SELECT database || '.' || name FROM system.tables
   WHERE name = 'events' AND database NOT IN ('system')
   ORDER BY database LIMIT 1
   ```
2. **Get a site id**, creating a dedicated throwaway site if none exists, so the
   check never writes into real analytics. No site means the verdict is
   *not configured* — which is not a claim about ingestion.
3. **Count first**, post the synthetic event, then **poll** until the count
   rises. Ingestion is asynchronous; sampling once is a race. About five seconds
   is typical.

Send the payload Rybbit actually accepts. Two details, both from its own schema
(`server/src/services/tracker/trackingPayload.ts`), and both of which make a
healthy stack look broken when you get them wrong:

```json
{"type": "pageview", "site_id": "1", "pathname": "/colors-acceptance"}
```

- It discriminates on **`type`**, not `name`. Anything else is `400 Invalid
  discriminator value`.
- **`site_id` is a string.** It is `z.string()`, so the bare number is rejected
  and your check reports `rejected` against a working deployment.

Send it with an ordinary **browser User-Agent**. Sites default to `blockBots:
true`, and a request classified as a bot is answered `200` with the event
diverted away from the events table — so a `curl/8.x` agent produces a `dropped`
verdict that looks exactly like a broken pipeline.

Distinguish the outcomes, because they point at different layers:

| Verdict | Meaning | Where to look |
|---|---|---|
| `ingested` | count rose | — |
| `dropped` | `2xx`, no stored row | **bot blocking first**, then backend → ClickHouse, schema, JSON types |
| `rejected` | non-2xx | payload shape first, then the backend and proxy routing |
| `unreachable` | no response | Caddy, DNS, TLS |
| `not-configured` | no site exists | nothing was tested; do not report success |

Keep `not-configured` visually distinct from success in whatever you print. A
check that silently skips itself under a common condition looks exactly like a
check that passes, and that is how the `type`-discriminator bug survived every
converge until a site finally existed.

### Backups — confirm the object, not the unit

Capture a timestamp, trigger the backup, then list the bucket prefix and require
a non-empty object whose modification time is not older than that timestamp.
Comparing against a timestamp taken *before* the trigger is what makes this a
test of this run rather than of some run.

The restore drill belongs inside the backup script itself rather than in
acceptance: it has to gate the upload, so a bad dump never reaches the bucket at
all.

### Signup policy — ask the running application

After changing it, read `/api/config` from the live host. The file on disk and
the running container disagree until the services are recreated, and the file is
the one that looks right.

## Structuring the check

Keep the verdict logic pure and unit-test it — the ingestion verdict, the backup
freshness rule, the site-id parse. The I/O is untestable without a live host,
but the decision rules are exactly where mistakes hide.

The concrete example worth avoiding: an early version computed the track result,
stored it in the result map, and then never referenced it in the branch that
reported success — so it announced success unconditionally, including when the
endpoint had rejected the request. The fix is not "be careful"; it is to make the
success branch structurally depend on the verdict.

`../scripts/acceptance.sh` implements all of the above.
