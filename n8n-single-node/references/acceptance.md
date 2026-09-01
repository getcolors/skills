# Acceptance doctrine

What each gate checks, and — more usefully — what a *weaker* version of it would
have let through. Every gate below ran on a live deployment; the implementation
lives in `getcolors/n8n`.

## Storage tier

**The tenant and timeline in desired state are the ones attached.** Fixing those
identifiers in desired state is what makes the check possible at all; a
deployment that mints them at runtime has nothing to compare against.

**Remote storage is real *and fresh*.** Pageserver object *existence* only —
layer uploads follow the checkpoint cadence, so demanding a new one per converge
flakes. But after `pg_switch_wal()` a **new** safekeeper segment must appear
beyond a pre-switch sorted baseline. Historical objects must not satisfy the WAL
gate, or a broken uploader hides behind them indefinitely.

**n8n is really on the intended database.** Not "the tables exist and there is
no SQLite file" — that can pass while the live process writes somewhere else.
Create a uniquely tagged workflow through the running instance's **API**, then
read that exact row back through a direct database connection. Separately assert
`DB_TYPE=postgresdb` in the running container: the real silent-SQLite trap is a
`DB_TYPE` typo, not a missing connection variable.

**The schema matches the pinned image.** Gate the migrations table's contents,
not a log line. Logs rotate, wording changes across versions, and a partially
applied migration still logs progress.

## Application tier

**Liveness and readiness, separately.** `/healthz` returns 200 while the
database connection is still initialising; `/healthz/readiness` is the one that
gates on the database. Collapsing them into one check is how dependents start
against an instance that cannot serve a request.

**Origin TLS from the host, origin reachability from outside.** Once the
firewall admits only the CDN, a workstation cannot reach the origin at all — so
the certificate check runs host-locally against loopback with the public SNI,
and the "origin refuses non-CDN traffic" check runs from the workstation over
both address families. One probe cannot satisfy both; they need different
vantage points.

**The generated production webhook URL, exactly.** This is what catches the
deprecated `WEBHOOK_URL` spelling: with it, n8n falls back to its own host and
port and hands third parties a URL that never resolves. Webhook URLs given to
third parties are effectively permanent, so a wrong one is not cosmetic.

**The owner account is claimed — before the public name resolves.** n8n's
first-run setup screen is unauthenticated: between the proxy serving the name
and an owner existing, whoever arrives first owns the instance and every
credential it will ever store. Claim it during convergence over the internal
network, and gate the end state. Already-claimed is success, not an error, or
the converge stops being re-runnable.

**A Code node *executes* on the runner.** Not "a runner registered" — the log
wording is not stable across versions, and a runner reports connected long
before it has run a task. That is exactly the failure mode of a runner/main
version mismatch. Only execution distinguishes a working runner from a connected
one.

**sshd rejects password and root-password authentication.** Where SSH is open to
the internet by convention, these negative controls are the entire mitigation,
so assert them rather than trusting an image default. Two notes: `sshd -T`
reports `prohibit-password` as the legacy synonym `without-password`, so a gate
matching only the modern spelling accuses a correctly hardened host; and capture
`sshd -T` **once** — invoking it per assertion lets a transient empty result
make two checks disagree about the same host in the same run.

## Load

A blocking soak with a **declared workload mix**, not a count. A bare count of
small executions meets every threshold without touching what actually breaks the
host: Code-node memory multiplication and binary-data churn. Include a
Code-node tier sized to trigger the payload duplication and a binary tier that
forces writes through the filesystem path.

Two **separately thresholded** latency measurements, because "database latency"
is otherwise whatever is easiest to report: application-role SQL round-trip
sampled independently, and end-to-end execution duration from the API. They are
different numbers and fail for different reasons.

Cleanup is part of the gate. A soak that leaves its rows behind poisons the next
run's measurements and every backup taken afterwards — and the cleanup's own
exit code is not evidence, because a DELETE that n8n refuses still returns
success per call. Assert the residue is gone.

## Retention

Qualify pruning in an **isolated scratch stack**, never against production:
declared retention is measured in hundreds of hours, and mutating it to
something observable would delete real history and violate the state being
converged. Upstream's intervals are unobservable in a drill anyway (soft-delete
hourly, hard-delete every 15 minutes) and have to be wound down.

The production gate is narrower by design: assert the **rendered** retention
values are the declared ones and that the prune workers are running.

## Restart

Two lifecycles, because they fail differently: a full `down` + `up` from
stopped, and an **unattended host reboot**. Both must return with no manual
sequencing — restart policies and health conditions only. Read the witness row
straight from the database rather than through the application, so the check
does not depend on the thing being restarted.

**A reboot drill cannot be a single in-host process**: it is killed by the very
event it is measuring. Split it into an arm phase that persists the witness and
triggers the reboot, and a check phase driven from the operator side once the
host is back.

## Recovery

Restore **both** artifacts into an isolated scratch stack — its own database and
its own data directory — boot the **pinned** image against them, and prove four
things a checksum cannot:

1. an operator can **log in** (whole-host recovery restores the database and the
   data directory but not the host's generated secrets, so a restore nobody can
   sign into is not a recovery)
2. the workflow rows are present
3. a stored credential **decrypts** — provable only by *using* it, since the API
   redacts credential values
4. a binary payload from the restored data directory is readable

**Readiness proves nothing about a restore.** The drill reported "boots ready
against the restored pair" while the scratch database was empty: n8n migrated a
blank database and reported ready. Assert restored *content* — the table count,
then the rows.

## The three meta-rules

**A gate that is never invoked is worse than no gate.** Inheriting a package's
acceptance *step* does not inherit its *gates*: the step is typically the
operator-side half, and a downstream play must invoke its own. This build's
first fully green converge reported success in 614 ms with zero application
gates executed.

**Time the acceptance stage and disbelieve a fast pass.** A suite that finishes
faster than its own sleeps is not running. The real suite takes 26 seconds
because of a 20-second WAL settle.

**Gate end state, never task outcomes.** Every task can be green while two
containers have never started.
