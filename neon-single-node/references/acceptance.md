# Acceptance doctrine

Exit codes are not evidence; each gate asks the system what it actually has.
All of these ran against the live deployment; the rehearsals are one-time
build verification, the gates run on every converge.

## Server-side gates (every converge)

1. **The SQL round-trip** through the published loopback port with the
   application role and a clean client environment (`env -i` with only PATH,
   `PGPASSWORD`, `PGPASSFILE=/dev/null`): create-if-absent one namespaced
   smoke table, upsert ONE deployment-scoped row deterministically
   (`INSERT … ON CONFLICT DO UPDATE`), assert count = 1. This is the single
   documented mutation excluded from the idempotence claim — a row keyed by
   run would break the second-converge check by construction.
2. **The negative space**: a wrong password refused, a passwordless
   connection refused (`psql -w`; a /dev/null PGPASSFILE makes psql *prompt*,
   not fail), and the application role refused a superuser-only action. An
   endpoint that accepts both authenticated and unauthenticated calls is
   indistinguishable from working unless this is checked.
3. **Remote storage is real, and fresh**: pageserver objects exist under the
   deployment's prefix (existence only — layer uploads follow the checkpoint
   cadence and demanding a new one per converge would flake), and after
   `pg_switch_wal()` a **new** safekeeper segment appears beyond a
   pre-switch listing baseline (comm against a sorted `rclone lsf`).
   Historical objects must not satisfy the WAL gate: a broken uploader
   would hide behind them indefinitely.
4. Only after all of that does the **ready marker** land, completing the
   two-phase ownership handshake the bootstrap opened — written with
   read-back verification, because a 0-byte marker satisfies existence
   forever.

## Operator-side gate (every converge, from the workstation)

The supported client path is exercised end to end: an `ssh -L` tunnel
through the *generated* `~/.ssh/config` alias (proving the alias, identity
file, and forward — not merely host-local loopback), the same clean-env
psql upsert through it, and the wrong-password refusal through it. Random
local port with retries; the tunnel is `ssh -f … sleep 45` wrapped in
`bash -c '… >/dev/null 2>&1'` (see the failure catalogue for why).

## Idempotence (the second converge)

Immediately re-running create must report no infrastructure changes (tofu),
re-render nothing that recreates compute (deterministic spec via stored
verifiers), reconcile the smoke row without duplicating it, and pass every
gate again. Verified.

## One-time rehearsals (build verification, not per-converge)

- **Pageserver wipe**: witness row + `pg_switch_wal`, stop compute then
  pageserver, `rm -rf` the local `tenants/` (38MB), start pageserver,
  re-attach via the same reconciling bootstrap (generation counter
  advanced to 2), force-recreate compute, read the data back. Proves the
  R2 copy is usable, not merely present — and that the surviving
  safekeeper's WAL replay closes the gap beyond the uploaded layers.
- **Fresh safekeeper**: stop compute + safekeeper, delete the safekeeper
  volume, start both (compute recreated) — reads AND writes work; the
  walproposer bootstraps the empty safekeeper from the compute basebackup.
  This is also the proof that a fresh safekeeper does NOT recover its
  offloaded WAL, which is what bounds the full-host RPO.
- **Rotation**: rotate the application role's password; the old password
  provably stops working before the new plaintext is recorded; a rollback
  (exercised for real once, via the spec-permissions trap) restores spec,
  verifier, plaintext, and compute together; no staging files remain.

## What was deliberately not gated

- `remote_consistent_lsn` thresholds at converge time: the metric reads
  0/0 after any restart or fresh attach and release images cannot force a
  checkpoint, so such a gate flakes on healthy systems and passes on
  unhealthy ones. Upload health is proven by the recovery rehearsal path
  and the fresh-segment WAL gate instead.
- In-compose healthchecks for the storage image: its shell tooling is
  unverified, and a false unhealthy would block converge on cosmetics.
  The converge asserts `/v1/status` on pageserver and safekeeper and the
  broker's listener from the host — including re-asserts after handlers
  may have restarted the tier.
