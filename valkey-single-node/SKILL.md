---
name: valkey-single-node
description: "Use when Valkey reports redis_version:7.2.4 beside valkey_version:9.1.2, NOAUTH or WRONGPASS exits zero, a restored dump.rdb answers PONG but DBSIZE is zero, an SSH audit exits successfully after only its first command or monitor, an R2 backup has no trustworthy completion marker, or a second converge appears to recreate a single-node Valkey service. Distilled from a verified Valkey 9.1.2 Vultr deployment with loopback-only access, R2 backups and scratch recovery. Includes the exact AOF restore trap, proof boundaries, and offline-only retention failure findings."
---

# Single-node Valkey

## Symptom index

Search [the failure catalogue](references/failure-catalogue.md) before changing the deployment:

- `redis_version:7.2.4` appears on the pinned Valkey 9.1.2 image.
- `NOAUTH Authentication required.` or `WRONGPASS` accompanies exit zero.
- A restored `dump.rdb` answers `PONG` but contains zero keys.
- An SSH audit stops after `Server identity`, or after `valkey-monitor: ok`, without a failure.
- A backup object exists but its completion marker is empty or unreadable.
- `StartedAt` changes on the second converge; is this a container replacement?
- `compute destruction is protected` blocks delete.
- Unrelated objects in the shared state bucket changed during testing.

## Provenance and ownership

These findings came from `valkey-vultr` on 2026-09-18: two successful
creates, two healthy describes, one recovery rehearsal, complete host audits,
and two deliberate scratch AOF/RDB comparisons. The deployment was retained.
Actual deletion and production-host recovery were not tested.

The evidence repository, [getcolors/valkey-vultr](https://github.com/getcolors/valkey-vultr),
is **private**; its links require repository access. Sanitized observations
are quoted in the references so diagnosis does not require credentials.
[Claim-to-evidence mapping](references/evidence.md) distinguishes live results
from offline review findings. No contradiction of upstream documentation was
established; the runtime observations stand on their own.

The public companion [getcolors/valkey](https://github.com/getcolors/valkey)
owns the launcher, configuration validation, tests, and templates under
`green/src/resources/io/github/getcolors/valkey/tools/`. The deployment owns
its audit probes. This Context Skill carries no copies of their working files.
Exact versions and retest conditions are in [pins](references/pins.md).

## Identity and authentication need exact replies

The same live `INFO server` response contains `redis_version:7.2.4`,
`server_name:valkey`, and `valkey_version:9.1.2`. The Redis version field is
compatibility metadata, not the Valkey build identity. Gate on both
`server_name` and the exact `valkey_version`.

Both anonymous and wrong-password PINGs exited zero while returning refusal
text. Read the reply: an authenticated PING must be exactly `PONG`;
an anonymous reply must contain `NOAUTH`; a wrong-password reply must contain
`WRONGPASS` or `NOAUTH` and must not contain `PONG`. An exit-code-only check
cannot prove authentication. The package uses `VALKEYCLI_AUTH` for its native
CLI; it passes the variable by name to Docker exec, without putting the
password in its arguments.

## Reachability and persistence are separate claims

The verified listener was exactly `127.0.0.1:6379`. The package's create
acceptance also ran the workstation tunnel round-trip, both authentication
negatives, and a bounded public-port refusal probe. The kernel listener and
outside probe are the evidence; firewall or Compose declarations alone are
not evidence of isolation.

The live service read back `noeviction`, `appendonly yes`,
`appendfsync everysec`, and healthy AOF status. Each converge deliberately
restarts the service and reads its smoke key back. Across the two converges,
the instance, SSH key, firewall, password, container ID and container creation
time remained unchanged. `StartedAt` changed because the smoke test restarts
the existing container. This proves graceful-restart persistence and the
observed convergence identity, not crash durability or a one-second loss bound.

## Backups and the restore trap

The rehearsal streamed an RDB, checked it using the pinned image, uploaded
RDB and manifest, verified their readbacks, then wrote the completion marker.
It restored a completed set into a scratch container with AOF disabled and
read the deployment's smoke key. The observed manifest held two keys and
288 bytes. Recovery verification is recorded separately under
`<profile>/valkey/.colors-recovery-verified`; it identifies the rehearsed set,
which need not remain the newest backup after a later converge.

The Redis reference's AOF trap was **reproduced against Valkey 9.1.2**.
Two scratch containers received the same RDB. With `appendonly no`, two keys
and the smoke key loaded. With `appendonly yes` and no existing AOF manifest,
the server created fresh AOF files, answered requests, and held zero keys.
`PONG` therefore proves neither data restoration nor recovery. Require
`loading:0`, the expected data, and the deployment identity as well.

This experiment does not establish a production restore procedure. In
particular, do not recommend simply putting an RDB beside an empty AOF
directory and starting the live service with AOF enabled: that is the
configuration the scratch experiment showed losing the restored view.

## Audit the auditor

An SSH-fed shell script originally stopped after its first Docker exec, yet
produced no failure. Closing stdin only on its direct execs got as far as the
monitor, whose nested exec consumed the remaining script. The completed
probe buffered its remote script before executing it, closed stdin for
commands that needed no input, and required `LIVE_AUDIT_COMPLETE`.

A second probe required `AOF_PROBE_COMPLETE`. Compare the actual output
against every expected section and terminal sentinel; an exit zero without
the final section is incomplete evidence. Preserve input deliberately when
streaming an RDB into a checker. Closing all stdin indiscriminately would
break the backup protocol.

## Shared buckets and offline review limits

Both existing buckets remained readable. Non-Valkey **backup** object counts
and path/size/modification-time hashes were unchanged. A concurrent
`redis-vultr-demo` appeared, and non-Valkey **state** objects increased from
10 to 12. The build supports namespace isolation for its own operations,
not a claim that the whole shared state bucket stayed unchanged.

Offline review found that treating an unreadable completion marker as
incomplete could let retention delete valid backups. The package now
propagates listing/read failures, finishes marker reads before pruning, keeps
the newest completed set, and leaves incomplete sets for manual inspection.
Mocked failure tests proved no purge on those read failures; destructive
retention was **not exercised live**. Shell/YAML injection rejection and
public-probe tool-error handling were also offline review/test findings.

The R2 upload path worked with `no_check_bucket`, `no_head`, and known-size
`copyto`. This build did not remove those flags, so it does not prove which
ones R2 requires. Other providers, managed buckets, teardown, and recovery
onto a replacement production host remain unverified. Use the
[acceptance checklist](references/acceptance.md) when changing a pin.
