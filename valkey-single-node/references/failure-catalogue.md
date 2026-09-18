# Failure catalogue

Live observations below are from Valkey 9.1.2 on `valkey-vultr`, 2026-09-18.
Evidence links are indexed in [evidence.md](evidence.md); that repository is
private. Offline findings are labeled separately.

## `redis_version:7.2.4` on a Valkey 9.1.2 image, live

The exact live identity was:

```text
redis_version:7.2.4
server_name:valkey
valkey_version:9.1.2
```

Nothing had downgraded the server. Checking `redis_version` had checked the
compatibility field. Use `server_name:valkey` and `valkey_version:9.1.2` for
this pin. Observed in both complete audits.

## `NOAUTH Authentication required.` with exit zero, live

```text
anonymous rc=0 reply=NOAUTH Authentication required.
wrong rc=0 reply=AUTH failed: WRONGPASS invalid username-password pair or user is disabled.
NOAUTH Authentication required.
```

Both refusals are successful CLI process exits. Parse replies and reject any
negative probe containing `PONG`. The positive control must return `PONG`.
Observed in both complete audits; tunnel acceptance ran on both creates.

## Restored `dump.rdb`, `PONG`, and zero keys, live reproduction

The same 288-byte RDB gave these results in the second comparison:

```text
appendonly=no DBSIZE=2 smoke=20260918T155249Z
appendonly=yes DBSIZE=0 smoke=
```

The AOF-on server logged:

```text
Creating AOF base file appendonly.aof.1.base.rdb on server start
Creating AOF incr file appendonly.aof.1.incr.aof on server start
Ready to accept connections tcp
```

These are verbatim message bodies, with timestamp/PID prefixes omitted.
With AOF enabled and no existing AOF manifest, this Valkey build starts an
empty AOF data set instead of loading the supplied RDB. The scratch restore
uses AOF off, waits for `loading:0`, checks key count, and reads `colors:smoke`.
This was reproduced twice, not merely inherited from the Redis reference.
No production-volume replacement procedure was executed.

## SSH audit exits after `Server identity` or `valkey-monitor: ok`, live

The first audit's application section ended at:

```text
Server identity
redis_version:7.2.4
server_name:valkey
valkey_version:9.1.2
```

The first attempted fix reached `valkey-monitor: ok` but omitted timers,
manifest and recovery marker. Docker Compose `exec -T` still attaches stdin;
a child consumed bytes from the shell script being delivered over SSH. The
monitor contained another exec, so patching only direct calls was incomplete.

Buffer the remote script before executing it; close stdin for commands that
need none, including nested helpers; require a final sentinel. The completed
runs contain `LIVE_AUDIT_COMPLETE`; the final scratch comparison additionally
contains `AOF_PROBE_COMPLETE`. Lack of an error is not proof all sections ran.
Do not close stdin on the intentional RDB stream/checker path.

## `StartedAt` changed after a second create, expected live behavior

Both complete audits report the same container ID and `CreatedAt`, while
`StartedAt` changes. The smoke acceptance deliberately restarts the existing
service. Compare instance identity, container ID/creation time and password
stability; treating `StartedAt` alone as replacement would report false drift.

## `compute destruction is protected`, live guard, not teardown proof

```text
compute destruction is protected; set COLORS_PAR_COMPUTE_PREVENT_DESTROY=false to delete
GUARDED_DELETE_EXIT=2
```

The guarded command refused as intended, leaving resources in place at that
time. Later explicit user authorization permitted a one-run override. Actual
delete exited zero in 61 seconds; repeat-delete exited zero in 3 seconds.
Independent audits found the owned instance, firewall and provider SSH key
IDs returned 404, and the managed local key files and SSH config block were
absent. Both shared buckets remained readable, with 20 profile backup objects
preserved. The original guard refusal alone did not prove these later facts.

## Completion-marker read failure looks like an incomplete set, offline only

Review found a branch that swallowed marker-read failures and pruned old
incomplete sets. Its mock regression uses `403 AccessDenied` and
`connection reset`; these are **test fixtures**, not live R2 errors.

A failed read cannot establish absence. Successful per-set listing proves
whether a marker is absent; present markers must be read successfully.
Complete all reads before deleting anything. Keep incomplete sets for manual
inspection and keep the newest completed set even when old. The package's
mocked retention tests passed; no deliberately destructive retention test ran
against the shared bucket.

## `lost the AWS provider switch or the rclone skips`, offline scope mismatch

```text
golden: valkey-fixture r2-env.sh lost the AWS provider switch or the rclone skips
```

A copied Redis golden expected an AWS application-storage branch, outside the
Valkey existing-R2 scope. The assertion was adapted to require Cloudflare and
both R2 flags. This was an offline test failure; it is not evidence that an
AWS deployment was attempted or supported.

## `AssertionError` during a broad shared-state comparison, live observation

The session notes record `AssertionError` after a separate `redis-vultr-demo`
instance appeared and non-Valkey state objects increased from 10 to 12.
Valkey identities stayed stable and non-Valkey backup metadata stayed
unchanged. Account-wide concurrent work made the original global-unchanged
assertion unsupported. Preserve unrelated resources and narrow the report to
what was measured; do not modify the unrelated deployment to make a test pass.
