# Failure catalogue

Every entry was hit on a real converge of a live Rybbit deployment. They are
grouped by area; within a group the ordering roughly follows the sequence a
fresh build encounters them.

**How to use this:** search for your symptom string first — many of these are
verbatim error text. If your symptom is "it reported success and nothing
happened", read the whole file, because that describes most of them.

Only a handful are Rybbit-specific. The rest are what any single-node stack
behind a proxy with a database and a backup unit will eventually do to you.

## Contents

- [Configuration delivery](#configuration-delivery)
- [Ingestion and the track API](#ingestion-and-the-track-api)
- [Verification that lied](#verification-that-lied)
- [ClickHouse](#clickhouse)
- [Backups](#backups)
- [Proxy, DNS and logging](#proxy-dns-and-logging)
- [Host and provider](#host-and-provider)
- [Images and pins](#images-and-pins)

---

## Configuration delivery

### Every Caddyfile edit landed on disk and never reached Caddy

**Symptom.** You change the Caddyfile, converge, and the behaviour does not
change. The file on the host is correct. Ansible reports the copy as `changed`.
`docker compose ps` shows Caddy running and healthy. Diffing the host file
against your intent shows exactly what you wanted.

**Cause.** Two mechanisms compounding. The Caddyfile is bind-mounted as a
*single file*, and `ansible.builtin.copy` replaces files by rename — so the
running container keeps the inode it started with and never sees the new
contents. Then `docker compose up -d` declines to recreate a service whose
definition has not changed, and the service definition did not change; only the
file behind the mount did.

**Fix.** Compare the checksum Caddy is actually serving against the file on
disk, and key a `--force-recreate` on that difference rather than on Ansible's
change flag. Observed-versus-desired also repairs a container that went stale
for an undiagnosed reason.

**Apply it to every single-file mount, not just the noisy one.** This stack has
two — the Caddyfile and the ClickHouse `users.d` profile — and the ClickHouse
one is the more dangerous because a stale JSON-type setting surfaces as a schema
that will not build rather than as a missing header. The same trap bit twice in
the PostHog sibling, in two different services. Enumerate your file mounts and
reconcile all of them; `assets/ansible/main.yml` loops over the list.

A directory mount does not have this problem — the container follows the
directory, so files created or replaced inside it are visible. Mounting the
parent directory is therefore an alternative fix, at the cost of shadowing
anything the image ships in that directory.

**Why the obvious checks mislead.** `docker compose restart` re-execs the
process inside the *same* container against the *same* stale mount, so a config
that is re-read at startup is re-read from the old inode. That makes "I
restarted it and nothing changed" look like evidence that the file is not the
one being read, when it is entirely consistent with the correct file at the
correct path.

### Changing the signup policy did nothing, silently

**Symptom.** `rybbit-disable-signup` is flipped in desired state and converged.
The playbook reports success. Registration behaviour is unchanged. The value in
`stack.env` on the host is still the old one.

**Cause.** `stack.env` holds generated passwords that must survive a converge,
so it is written once under `creates:`. That correctly protects the secrets and
incorrectly froze everything else in the file, including a setting that decides
whether strangers can create accounts on a public analytics instance.

**Fix.** Keep policy lines in step with `lineinfile` while leaving the generated
secrets write-once. That is necessary but not sufficient — see the next entry.

### The file changed and the containers kept the old value

**Symptom.** `stack.env` on the host now shows the new value. The running
backend still behaves as it did before.

**Cause.** `env_file` is consulted when a container is **created**, not while it
runs. A restart is not enough either.

**Fix.** `docker compose up -d --force-recreate backend client` when the policy
line changes. Verify against the live `/api/config`, not against the file.

---

## Ingestion and the track API

### `400 Invalid discriminator value`

**Symptom.** The synthetic event is rejected:

```
400 {"error":"Invalid payload","details":{"fieldErrors":{"type":[
"Invalid discriminator value. Expected 'pageview' | 'custom_event' | ..."]}}}
```

**Cause.** Rybbit's `/api/track` discriminates on `type`. A payload sending
`name` with a nested `data` object is rejected outright.

**Fix.** Send `{"type": "pageview", "site_id": <id>, "pathname": "/..."}`.
Verified against the live deployment: the corrected payload succeeds and the row
reaches the ClickHouse events table within about five seconds.

**Why it hid for so long.** The check reports `not-configured` and sends nothing
when no site exists, which was true of every converge until a site was finally
added. A check that skips itself under a common condition is indistinguishable
from a check that passes. Make the skipped verdict visibly different from the
success verdict.

### A `200` and no row, because the request looked like a bot

**Symptom.** The synthetic event is accepted and never stored. Every container
is healthy. The verdict is `dropped`, which points you at ClickHouse, and
ClickHouse is fine.

**Cause.** Bot blocking. A site's `blockBots` defaults to **true**, the classifier
runs on the User-Agent, and a detection is answered `200 {"success":true}` with
the event diverted away from the events table. Returning an error would make the
endpoint a fingerprinting oracle, so success is the deliberate design — which
means a bot-classified request is indistinguishable from a broken pipeline at
the HTTP layer.

**Fix.** Send an ordinary browser User-Agent from any synthetic check. A bare
`curl/8.x` is a plausible detection, and so is a "helpful" custom agent naming
your tooling. When a check reports `dropped`, rule this out **first** — it is
cheaper than everything else on the list and it is the one cause that leaves no
error anywhere.

Verified against upstream source, not inferred.

### Acceptance wrote test rows into production analytics

**Symptom.** A `/colors-acceptance` pageview appears in the operator's real site
statistics after every converge.

**Cause.** The synthetic event was sent to whichever site happened to be first
in the table.

**Fix.** Create a dedicated throwaway site on demand and send there. Attach it
to the existing organization so it stays visible and deletable in the UI, and
make its domain configurable so it never collides with a real one.

---

## Verification that lied

### The check reported success for a response it never read

**Symptom.** Acceptance passes. The endpoint returned an error.

**Cause.** The step captured the `/api/track` response into a variable, recorded
it in the result map, and never branched on it. The success path did not depend
on the result it had just computed.

**Fix.** Compute a verdict and make the success branch depend on it. Keep the
verdict rules pure and unit-test them; the I/O needs a live host but the
decision logic does not, and that is where this class of bug lives.

### `psql` output parsed as a site id

**Symptom.** The site id extracted from a query is not a number, and the
subsequent request fails in a way that points at the wrong layer.

**Cause.** `psql` prints the `INSERT` tag before the `SELECT` result, so the
whole output is not an id.

**Fix.** Take the last line and require it to match `\d+`. If it does not, that
is a distinct verdict, not a fallback.

### A quoted SQL literal arrived at `psql` verbatim

**Symptom.** A syntax error from `psql` on a query that is correct when you run
it by hand.

**Cause.** The query travels inside single quotes in a remote shell. An escaped
single quote does not survive that trip.

**Fix.** Dollar-quote the literals (`$$value$$`). No escaping, no shell
interaction.

### The events table could not be found

**Symptom.** The count query fails against a database name that does not exist.

**Cause.** The check hardcoded a database name that Rybbit's migrations own and
may change.

**Fix.** Resolve it at query time:

```sql
SELECT database || '.' || name FROM system.tables
WHERE name = 'events' AND database NOT IN ('system')
ORDER BY database LIMIT 1
```

### Sampling the event count once

**Symptom.** Intermittent acceptance failures that pass on a re-run.

**Cause.** Ingestion is asynchronous. Reading the count immediately after
posting is a race.

**Fix.** Record a baseline, post, then **poll** until the count rises or a
budget expires. Distinguish `dropped` (2xx, no stored row) from `rejected`
(non-2xx) from `unreachable` — they point at different layers.

---

## ClickHouse

### The schema does not build

**Symptom.** Rybbit's migrations fail against a stock ClickHouse server.

**Cause.** Rybbit's schema uses the experimental JSON and object types, which
are off by default.

**Fix.** Mount a `users.d` profile enabling the JSON type for the default
profile. It is a `users.d` profile setting, not a `config.d` server setting —
upstream's own compose carries the comment "Profile (user-level) settings are
only read from users.d, not config.d". Putting it in `config.d` is accepted and
ignored.

**The setting name depends on the ClickHouse version, and a wrong one is
ignored rather than rejected.** This is the nastier half: the server starts, the
profile looks installed, and the schema still will not build.

| ClickHouse | Setting |
|---|---|
| 24.8 (the verified pin) | `allow_experimental_json_type`, `allow_experimental_object_type` |
| 25.x and later (current upstream) | `enable_json_type` — the object-type setting is gone entirely |

Never assume; ask the server what it actually loaded:

```sql
SELECT name, value FROM system.settings WHERE name LIKE '%json_type%'
```

This is the general hazard with any experimental setting: promotion out of
experimental renames it, and a renamed setting is silently inert.

### The health probe depended on name resolution

**Symptom.** The ClickHouse health check fails in a way unrelated to ClickHouse.

**Cause.** The probe used `localhost`, whose resolution inside a container is
not guaranteed to be what you assume.

**Fix.** Probe `http://127.0.0.1:8123/ping` explicitly.

---

## Backups

### `not allowed for backups, see backups.allowed_path`

**Symptom.** The `BACKUP` statement is refused every time.

**Cause.** The destination named a **host** path from inside the container.
ClickHouse only writes backups under its configured `backups.allowed_path`.

**Fix.** Write to a path under the server's allowed path that also sits on the
bind mount, so the host can collect the archive afterwards. Create the directory
and `chown` it to the `clickhouse` user — otherwise the statement fails on
permissions instead.

### `file changed as we read it` — and one lucky backup in the bucket

**Symptom.** The backup unit exits non-zero. Object storage holds a single
object from weeks ago. Nothing alerted, because the timer kept starting
successfully.

**Cause.** A `||` fallback tarred the live ClickHouse data directory when
`BACKUP` failed. A hot tar races the server's own merges — parts vanish
mid-read — so tar exits non-zero, `set -e` aborts the script before the upload,
and the archive it produced would not have restored anyway.

**Fix.** Delete the fallback. An archive that cannot be restored is worse than a
failed unit: it looks like a backup right up until you need it. A failed
ClickHouse backup must fail the whole run, loudly.

### The archive existed and had never been restored

**Symptom.** None, until a restore is attempted.

**Cause.** The unit produced an archive and checked nothing about it.

**Fix.** Before uploading, load the dump into a scratch database and require the
schema back — count `information_schema.tables` and fail if it is empty. Drop
the scratch database in a trap so a failure does not leave it behind. A
truncated or malformed dump then fails the unit instead of reaching the bucket.

### Retention pruned the disk and the bucket grew forever

**Symptom.** Local backups respect the retention window. The object storage bill
does not.

**Cause.** The retention setting only drove a local `find -delete`.

**Fix.** Prune the remote prefix to the same horizon
(`rclone delete --min-age <N>d`). Retention that applies to one copy is not a
retention policy.

### The backup check confirmed the timer, not the backup

**Symptom.** Acceptance passes on a deployment with no recoverable data.

**Cause.** The check started the unit and confirmed the timer was active.
Neither says an object exists, is non-empty, or is new.

**Fix.** Capture a timestamp before triggering, then list the bucket prefix and
require a non-empty object whose `ModTime` is not older than that timestamp.

---

## Proxy, DNS and logging

### No request-level evidence that anything ever arrived

**Symptom.** Ingestion needs debugging and there is nothing to read. The proxy
recorded only errors and TLS events.

**Cause.** Caddy does not log successful requests by default. For an endpoint
whose entire job is receiving requests, that removes the primary evidence.

**Fix.** Log to stdout in JSON, where `docker logs` reads it. Bound it in the
same change: the `json-file` driver does not rotate, and this is one line per
request, so an ingestion endpoint under load fills the disk. 10MB across 5 files
per service.

### The access log recorded the CDN's address, not the visitor's

**Symptom.** Every request in the log comes from a Cloudflare edge address —
`162.158.94.194` and friends. The log exists and is useless for the one question
it gets read for.

**Cause.** Behind a proxy every connection arrives from the edge. Without
`trusted_proxies`, Caddy attributes the request to its immediate peer, which is
the edge.

**Fix.** Declare the proxy's ranges in `trusted_proxies` so Caddy reads
`X-Forwarded-For`. Verified live by comparing two deployments behind the same
edge: the one carrying the block logged the real client address for the same
request the other recorded as the edge.

**Scope of the fix.** This changes what *Caddy* sees and logs, not what the
applications store — they read `X-Forwarded-For` themselves, which is why event
attribution was already correct. Do not go looking for corrupted analytics data;
the damage was confined to the log.

**When you port.** These ranges describe Cloudflare. If nothing proxies your
origin the block is inert but misleading. If something else does, it is wrong,
and wrong in the silent direction.

### The origin address was published in DNS

**Symptom.** The host resolves directly to the machine. The firewall is the only
thing in front of it.

**Cause.** The DNS record defaulted to unproxied, so a deployment got the weaker
posture unless whoever wrote the configuration knew to ask for the stronger one.

**Fix.** Proxy by default; make opting out explicit. Verified after converging
that an event ingested through the edge still records the client's own ASN
rather than the CDN's, so geo and ASN attribution are unaffected.

**The cost.** SSH to the hostname stops reaching the machine. Converges are
unaffected because the playbook uses the address the provider emitted, but an
ad-hoc SSH needs the origin address. That is the trade, and it is worth taking.

### The DNS zone lookup could not match

**Symptom.** The zone data source finds nothing and the apply fails.

**Cause.** It filtered on the fully qualified host name rather than the
registrable zone.

**Fix.** Derive the zone from the host — everything after the first label, when
there are more than two — or let it be configured explicitly for the cases where
that heuristic is wrong.

### A test asserted the wrong thing and could not have caught the default

**Symptom.** The proxied-record default was wrong and the test suite was green.

**Cause.** The test asserted that the string `proxied` appeared in the rendered
record. That is true of an unproxied record too.

**Fix.** Assert the value, not the presence of the key, and cover the opt-out
separately. A test that cannot fail is not a test.

---

## Host and provider

### Every create failed on its first task with a 404

**Symptom.** Package installation fails on a fresh machine, naming a version the
archive no longer carries.

**Cause.** `cache_valid_time` let Ansible skip the apt update. A fresh cloud
image ships package lists old enough that the versions they name have already
been superseded.

**Fix.** `update_cache: true` with no `cache_valid_time`. The cost of a refresh
every converge is trivial next to a create that cannot start.

### The machine kept the image's hostname

**Symptom.** The host does not know the name you gave it in desired state.

**Cause.** Nothing set it; the resource name is a provider-side label.

**Fix.** Set it from desired state in the playbook. This also keeps the fix
provider-independent — see the note in `providers.md` about Vultr, where setting
`hostname` on the resource forces a reinstall.

### Ansible was pointed at `192.0.2.10`

**Symptom.** A converge fails as though the host were unreachable. The host is
fine.

**Cause.** The credential-free build and dry-run paths render with a
documentation address (TEST-NET-1). A real run merged fallback parameters and
then the provider outputs, so a **missing** address output left the placeholder
in place rather than failing.

**Fix.** On a real event, require the address and fail with a message naming the
actual problem. A missing provider output should never be able to present itself
as an unreachable host.

### `This size is not available because it has a smaller disk`

**Symptom.** Every attempt to move the machine to a cheaper plan is refused with
a 422.

**Cause.** DigitalOcean permits a resize only to a plan whose disk is at least
the current disk. A 160GB droplet therefore cannot reach any plan at or below
8GB of RAM.

**Fix.** There is no in-place fix. `resize_disk = false` does not help — that was
checked against the live API rather than reasoned about, and the API refuses the
move regardless. The downsize is a delete, a recreate at the target size, and a
restore from backup, which is only survivable because the backups were already
proven restorable.

**The lesson is about sizing up, not down.** Verify the restore path before you
need it, and be conservative with the initial plan: measured on the running
stack, six containers held about 1.0GB resident with load average 0.7 across
four vCPUs and 6.2GB of disk. Half the original plan was ample.

### The machine was named after its region

**Symptom.** The provider console shows a machine whose name duplicates
information already carried by the region field and reads like a different
deployment.

**Cause.** It was named `rybbit-ams3` rather than after the deployment.

**Fix.** Name compute after the deployment. The provider renames the machine and
its firewall in place, so the existing host, its address and its volumes are
untouched — on DigitalOcean. Check before assuming that on another provider.

---

## Images and pins

### Both application images tracked `:latest`

**Symptom.** None yet. That is the point.

**Cause.** `rybbit-backend` and `rybbit-client` were both on a moving tag, so a
converge could deploy something different with no change on your side.

**Fix.** Pin by digest. The sibling PostHog deployment demonstrated the failure
mode this avoids: an application and a plugin server built from different
commits, with the consumer dying on a column the other image's migrations had
never created — and no change on the operator's side to explain it.

### Validation rejected the strongest available pin

**Symptom.** A digest-pinned image is refused by your own configuration check.

**Cause.** The image pattern required `name:tag` and forbade `@`.

**Fix.** Accept `name:tag`, `name@sha256:…` and `name:tag@sha256:…`. A digest is
the only pin that cannot move; a validator that rejects it makes the correct
configuration inexpressible.
