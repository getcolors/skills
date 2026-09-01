# Failure catalogue

Symptom-indexed. Search for the string on your screen.

Every entry was observed on a running deployment during the build that produced
this skill. Where a fix is stated, it is the fix that made the gate pass.

---

## `Mismatching encryption keys. The encryption key in the settings file /home/node/.n8n/config does not match the N8N_ENCRYPTION_KEY env var`

```
Error: Failed to load command "start"
Error: Mismatching encryption keys. The encryption key in the settings file
/home/node/.n8n/config does not match the N8N_ENCRYPTION_KEY env var.
```

n8n persists `N8N_ENCRYPTION_KEY` into `/home/node/.n8n/config` on **first
boot** and refuses to start afterwards if the environment disagrees. **One bad
first boot poisons the data directory permanently**, and the error appears on
the *next* boot, so the cause is already off-screen.

**Do not automate the repair.** Deleting the settings file is correct only when
the database holds no encrypted credentials. When it does, that file is the only
thing that can decrypt them and removing it destroys them silently. Fail with
both options stated:

- credentials exist → restore the **original** key; do not delete anything
- failed first boot, nothing stored → remove the settings file, re-converge

**Diagnostic trap:** comparing the two keys by fingerprint with
`printf '%s\n' "$K" | sha256sum` on one side and Python's
`sha256(k.encode())` on the other disagrees by the trailing newline and reports
a false mismatch. Hash both sides without it.

---

## `password authentication failed for user "n8n"` — and the credential is correct

```
Initial database connection attempt 1 failed: password authentication failed
for user "n8n". Retrying in 1000ms
...
dependency failed to start: container neon-n8n-1 is unhealthy
```

The message points at the database. Check what the container actually received:

```
DB_POSTGRESDB_PASSWORD: "{{ lookup('file','/etc/neon/secrets/neon_role_password') }}"
```

The template was copied through **literally** and n8n authenticated with that
string. Two compounding causes:

1. `ansible.builtin.copy` with `src:` does **not** render templates —
   `ansible.builtin.template` does. But `content:` *is* rendered, because module
   arguments are templated. That inconsistency is what makes it easy to miss:
   a sibling task using `copy: content:` with a lookup works perfectly.
2. Even with `template:`, **an Ansible lookup executes on the controller**. A
   path that exists only on the managed host can never be read by
   `lookup('file', …)`.

**Fix:** secrets reach containers through an `env_file` written **on the host**,
split by origin — host-generated values assembled there, controller-supplied
values via `copy: content:`. Add a guard that greps the rendered env files for
an unrendered template opening; the failure mode of one is an authentication
error that sends you to the wrong subsystem entirely.

---

## `/healthz` returns 200 but every API call answers `503 {"code":503,"message":"Database is not ready!"}`

```
/healthz            HTTP/1.1 200 OK
/healthz/readiness  HTTP/1.1 503 Service Unavailable
```

`/healthz` is a **liveness** probe — it returns 200 as soon as the process
listens. `/healthz/readiness` is the one that gates on the database.

This is not only a probe-script bug. A Compose healthcheck using `/healthz`
marks n8n healthy early, and anything with `depends_on: service_healthy` — a
reverse proxy, a task runner — starts against an instance that cannot serve a
request. Gate both, separately, so the distinction cannot regress.

---

## `400 {"code":400,"message":"Workflow must be archived before it can be deleted."}`

n8n 2.x will not delete a live workflow. Two steps, verified:

```
POST /rest/workflows/{id}/archive -> 200
DELETE /rest/workflows/{id}       -> 200 {"data":true}
```

A DELETE-only cleanup reports success per call and leaves every workflow behind.
This was caught only because the gate asserted the residue was gone rather than
trusting the cleanup's exit code — a load test that leaves its own rows behind
poisons the next run's measurements and every backup taken afterwards.

---

## `400 {"code":400,"message":"To run the workflow manually, specify either a trigger to start from or a destination node."}`

An empty body is refused. All three plausible shapes, probed live:

```
triggerToStartFrom -> 200 {"data":{"executionId":"1"}}
startNodes         -> 400  (same message)
destinationNode    -> 400  "Expected object, received string"
```

Only `{"triggerToStartFrom":{"name":"<node name>"}}` works, and it takes the
node's **name**, not its id.

**A 200 here means the execution was accepted, not that it succeeded.** A runner
that fails every task also returns 200. Poll `/rest/executions/{id}` for a
terminal status.

---

## An execution stays in `running` forever, never reaching a terminal status

A scratch or secondary stack inherited `N8N_RUNNERS_MODE=external` from the
production shape but has no runner sidecar. Every Code node then waits for a
task offer that never arrives — it does not fail, it hangs, so a drill times out
with something uninformative instead of reporting the cause.

Scratch stacks should run `internal` mode. In production, the same shape appears
when the runner image version does not equal the n8n image version: the runner
connects and then fails every task.

---

## `wget: unrecognized option: save-cookies` inside the n8n container

```
BusyBox v1.38.0 (2026-07-24) multi-call binary.
Usage: wget [-cqS] [--spider] [-O FILE] ...
```

The n8n image ships **BusyBox wget**, which supports `--post-data`,
`--post-file` and `--header` but has **no cookie jar at all**. Once the owner
account is claimed the REST API needs a session, so BusyBox cannot carry an
authenticated probe. Unauthenticated GETs (`/healthz`, `/rest/settings`) work
fine, which is why only the authenticated gate fails.

The image is Node 24 — use `node` with global `fetch` and handle
`getSetCookie()` yourself.

---

## A credential "decrypted to the wrong value"

```
status 200, keys ["name","value"], valueType "string",
valueLen 54, expectedLen 27, looksRedacted true
```

**n8n redacts credential values in API responses.** `GET
/rest/credentials/{id}?includeData=true` returns a **fixed-length sentinel**,
not the plaintext — 54 characters regardless of the stored value's length
(verified against 27- and 28-character secrets on the same instance, both
returning 54). So the length carries no information about the secret either. Comparing it against the value you stored fails forever and reads
as *"the encryption key did not survive"* — the most alarming possible false
negative in a recovery drill.

**Proving a credential decrypts requires using it.** n8n resolves and decrypts a
node's credential at execution time and fails the node if it cannot, so execute
a workflow whose node carries the credential and assert the execution reaches
`success`.

---

## `pg_dump: error: aborting because of server version mismatch`

```
pg_dump: detail: server version: 17.5; pg_dump version: 16.15
  (Ubuntu 16.15-0ubuntu0.24.04.1)
```

Ubuntu 24.04's `postgresql-client` is 16. **`psql` is protocol-compatible across
that gap and works perfectly**, so every query-based gate passes and gives no
hint; only `pg_dump`/`pg_restore` refuse. And only the backup path touches them,
so on a timer-driven schedule the mismatch surfaces hours after a converge that
reported success.

Run the dump and restore inside the database container, whose image carries
matching binaries.

---

## `could not open input file "/tmp/r.dump": No such file or directory` — after a successful `docker compose cp`

The destination container mounts a **tmpfs at `/tmp`**. `docker cp` writes into
the container's filesystem layer *underneath* that mount, so the copy reports
success and the file is invisible to processes in the container.

Pipe the file on stdin instead: `pg_restore … < dump`.

(The tmpfs itself is deliberate on a Neon compute — it prevents a stale
`/tmp/.s.PGSQL.55433.lock` from crash-looping a restarted container.)

---

## `rclone`: `InvalidArgument: Authorization  status code: 400`

Not a malformed request and not a wrong endpoint. rclone's S3 backend reads
`RCLONE_CONFIG_<REMOTE>_ACCESS_KEY_ID` / `_SECRET_ACCESS_KEY`; an environment
supplying only `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` leaves it
unauthenticated. There is no 401 and no "missing credentials" message — a 400
reading `InvalidArgument` is what an unauthenticated request looks like here.

Against a **bucket-scoped** R2 token also set
`RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true` (every upload is otherwise preceded by a
CreateBucket the token denies, surfacing as `AccessDenied` on what looks like a
plain write) and `RCLONE_CONFIG_R2_NO_HEAD=true`. Never `rclone rcat`: streaming
uploads of unknown size are `NotImplemented (501)` against R2 — `copyto` a file
of known size.

---

## Ansible: `Error loading tasks: failed at splitting arguments, either an unbalanced jinja2 block or quotes`

Ansible splits a shell task's arguments **before running anything**, counting
brace pairs and quotes across the whole block **including comments**. The error
names the task, never the character, and nothing in the file runs.

Three ways to hit it, all observed:

- two consecutive opening braces anywhere — *including in a comment describing
  the problem*
- a "fix" using a character class such as `'{[{]'`, which is also unbalanced
- any non-trivial nested quoting: a `python3 -c '…'`, a `docker exec` carrying
  its own quoted command, a JSON literal

**If a shell task needs quoting, put it in a script file the play installs and
calls.** A file has no such constraint and is testable with `bash -n`. Where a
pattern genuinely must contain braces, build it out of escapes:
`pat=$(printf '\173\173')`.

`ansible-playbook --syntax-check` reproduces the whole class offline in about a
second against the rendered tree — no credentials, no host, no cost.

---

## A converge reports success while containers sit in Docker state `created`

```
caddy|created|
n8n-runners|created|
```

Both declared `depends_on: service_healthy`. An earlier converge failed that
condition, leaving them created-but-not-started; every later run changed no
file, so the `notify:` handler that runs the bring-up never fired.

**A handler expresses "an input changed", not "the world should look like
this."** Desired-state convergence needs the enforcing command to run
unconditionally — `docker compose up -d` is idempotent and a no-op on a
converged host.

---

## Cloudflare: `data.cloudflare_zone.zone … 0 found`, while `/user/tokens/verify` says `Invalid API Token`

```
Error: failed to find exactly one result
  with data.cloudflare_zone.zone
   0 found
```

Probe the token directly and both answers are correct simultaneously:

```
GET /user/tokens/verify -> success: false, "Invalid API Token"
GET /zones              -> success: true, one zone
```

A **zone-scoped** token has no user-level scope, so the verify endpoint refuses
it while zone endpoints work. Diagnosing from `verify` alone sends you hunting a
broken credential that is perfectly valid.

**Always enumerate `/zones`** to learn what a token can actually reach.

---

## HTTPS never works, but the converge succeeded

If the origin firewall admits only Cloudflare's ranges and the DNS record is
**not proxied**, Caddy's ACME HTTP-01 challenge arrives from Let's Encrypt's own
addresses and is dropped. Nothing fails at converge time; the first HTTPS
request finds a certificate that was never issued.

The two settings are coupled: Cloudflare-only ingress **requires** a proxied
record. Make it a validator rule — the failure is otherwise separated from its
cause by hours.
