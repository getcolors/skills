---
name: redis-single-node
description: What a single-node Redis 7 deployment needs beyond the docs, verified live - a restored dump.rdb that loads ZERO keys because the instance started with appendonly yes and no appendonlydir/ beside it ("Creating AOF base file appendonly.aof.1.base.rdb on server start"), redis-cli refusals ("NOAUTH Authentication required.", "WRONGPASS invalid username-password pair") that exit 0 so a gate keyed on exit codes passes on a refusal, a `head -c` read of that reply that hangs until the timeout, Docker-published ports that bypass ufw (only the bind list and the provider firewall bound exposure), backups that stream `redis-cli --rdb -` instead of copying dump.rdb from the volume, and R2 backup sets that count only once a .complete marker reads back. Use whenever the user self-hosts Redis on one machine with Docker Compose, backs it up to S3-compatible storage, asks whether the AOF or the RDB is what restores, gates a converge on redis-cli output, or hits any symptom above. Full symptom index in the body.
---

# Single-node Redis

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim text in `references/failure-catalogue.md`:

- a restored `dump.rdb` comes up with `DBSIZE` 0 and the log says
  `Creating AOF base file appendonly.aof.1.base.rdb on server start`
- `NOAUTH Authentication required.` or `AUTH failed: WRONGPASS invalid
  username-password pair or user is disabled.` on stdout — with **exit 0**
- a health or smoke check that reads a redis-cli reply with `head -c N`
  and reports nothing, or blocks until its timeout kills it
- `ufw status` lists only 22 while a Docker-published Redis port answers
  from the network anyway
- a `docker inspect` `RestartCount` that never goes down, so a monitor
  flags a healthy container forever
- rclone against R2: `AccessDenied` on writes a bucket-scoped token should
  allow, or `NotImplemented ... 501` from `rcat`
- Ansible: `failed at splitting arguments, either an unbalanced jinja2
  block or quotes` on a shell task whose only oddity is an apostrophe in a
  comment
- a Colors/ONCE keygen deployment refusing its *own* provider SSH key
  ("not in this deployment's state") because state was normalized before
  the create matrix read it

Redis is easy to run and easy to run wrong in ways nothing reports. The
gap this skill covers is between a container that answers `PONG` and a
deployment whose claims were proven: which addresses actually listen, that
a refusal is a refusal, that a restart keeps the data, that a backup set is
a backup set, and that a restore restores. That distance was measured on a
live build — the `redis-vultr` deployment on 2026-09-03: two converges
(the first through the pinned launcher passed on its first run; the second
was the idempotence proof), one recovery rehearsal, one deliberate negative
probe of the AOF/RDB loading rule, and an authorized delete.

Everything here was verified against that running deployment unless it
says otherwise. Entries carried from sibling builds name the build that
paid for them.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/redis`](https://github.com/getcolors/redis) Package Skill —
the Compose file, the convergence play, the smoke gate, the backup and
restore-check scripts, the rehearsal play — under
`src/resources/io/github/getcolors/redis/tools/`, covered by that repo's
tests, golden fixtures and offline syntax gate, and consumed by the
[`redis-vultr`](https://github.com/getcolors/redis-vultr) deployment. This
skill carries no copies of them, per the Context Skill Standard's
no-second-copy rule. Read the templates there; read *why they are shaped
that way* here. Outside the Colors ecosystem the doctrine transfers
wholesale — only the OpenTofu/Ansible packaging is local.

## Topology that survived

One Vultr instance (`vc2-1c-2gb`, Ubuntu 24.04) in its own VPC, one Docker
Compose service running `redis:7.2.16` by digest, a firewall admitting 22
alone, and an SSH tunnel as the supported client path. No DNS, no public
port.

- **Exposure is decided by what Compose publishes, not by `bind`.** Inside
  the container Redis binds `0.0.0.0`; the host bindings
  `127.0.0.1:<port>:6379` and `<vpc-ip>:<port>:6379` are the whole of what
  can reach it. Verified with the kernel, not the config: `ss -ltnH "sport
  = :6379"` listed exactly `10.60.0.3:6379` and `127.0.0.1:6379`, and a
  bounded TCP connect from the workstation to the public address failed
  while the tunnel round-trip succeeded.
- **The VPC address is a run-time fact.** It reaches the Compose file
  through the inventory and Ansible's `template:` (`{{ vpc_ip }}`), never
  through the build-time renderer, so a rendered tree carries no address.
- **The password is born on the host, once**
  (`/etc/redis/secrets/password`, `creates:`), lives in `redis.conf`
  readable by uid 999 alone, and is handed to `redis-cli` through
  `REDISCLI_AUTH` — `docker compose exec -T -e REDISCLI_AUTH=… redis
  redis-cli` — never on a command line, never in the container
  environment.
- **`maxmemory-policy noeviction` and `appendfsync everysec`** are asserted
  on every converge by `CONFIG GET` against the running server, not
  assumed from the file. A queue whose jobs can be evicted is a queue that
  loses jobs silently.
- **ufw is left as the image ships it** (enabled, 22 only). Docker's
  published ports bypass ufw through the DOCKER chain — verified on the
  langfuse-multi-node build; here the bindings and the provider firewall
  group are what bound exposure, and the acceptance proves the public
  address is closed rather than trusting either layer.

## Gates that ask the system what it has

Exit codes are not evidence with redis-cli: **error replies are text on
stdout and the process exits 0**. `PING` without a password prints
`NOAUTH Authentication required.` and returns 0; a wrong `REDISCLI_AUTH`
prints `AUTH failed: WRONGPASS …` then `NOAUTH …` and returns 0. Every gate
in the reference implementation captures the reply and greps it: `PONG`
for success, `NOAUTH`/`WRONGPASS` for the negatives, and a `PONG` in a
negative's reply is the failure. Capture into a variable first — a
`cmd | grep -q` under `pipefail` can fail on SIGPIPE after a match.

The converge gate then **restarts Redis** (`docker compose restart -t 30`)
and reads the key it just wrote: that is the append-only file doing its
job, proven rather than configured. A second of unavailability per
converge is the price, and on a cache/queue tier it is the right one.

The workstation-side acceptance opens the SSH tunnel through the generated
`~/.ssh/config` alias (`ssh -f -o ExitOnForwardFailure=yes -L
<port>:127.0.0.1:6379 <alias> sleep 45`, wrapped in `bash -c … >/dev/null
2>&1` so the runner is not held by the daemonized child's pipes), runs
`SET`/`GET` with the password read over SSH, then the two refusals, then
the public-port probe.

## Backups that are backups

- **Stream the snapshot, do not copy the file.** `redis-cli --rdb -` asks
  the server for a replica-style full sync (`REPLCONF rdb-only 1`, diskless
  with an EOF marker on 7.2): a point-in-time fork, no reads from the data
  volume, no interaction with the live AOF. The payload is stdout and the
  transfer log is stderr, so `docker compose exec -T` keeps them apart.
- **Verify with the image's own checker before the set counts**:
  `redis-check-rdb` piped in through `sh -c 'cat > /tmp/x.rdb && …'` inside
  the running container, so nothing lands on the volume.
- **Completion protocol**: `dump.rdb`, `manifest.txt` (stamp, image,
  server version, `DBSIZE`, sha256, bytes), then — only after `rclone
  lsjson` size and a `rclone cat | sha256sum` read-back match — the
  `.complete` marker, itself verified by read-back. A set without a
  non-empty marker does not exist to the restore, the monitor or the
  pruner. Emptiness counts as absence.
- **rclone against R2 on Ubuntu 24.04's 1.60.1** needs
  `no_check_bucket`, `no_head`, and never `rcat` — carried from the
  neon-single-node build, where each flag was paid for; this build ran
  with them from the start and did not re-test without.

## The restore doctrine, and the trap it exists for

**A Redis 7 started with `appendonly yes` and no `appendonlydir/` beside
`dump.rdb` loads nothing.** It creates an empty AOF base and increment file
on start, logs `Creating AOF base file appendonly.aof.1.base.rdb on server
start`, answers `PONG`, and reports `DBSIZE` 0 — the RDB is never read.
Reproduced deliberately on the live host with the just-restored 288-byte
set (2 keys under `--appendonly no`, 0 keys under `--appendonly yes`).

So the rehearsal restores into a **scratch** container of the pinned image
with `--appendonly no --save "" --dir /data --dbfilename dump.rdb`, no
published port, no password, reached only through `docker exec`, and
removed by an `EXIT` trap whatever happened. It waits for `PONG` and
`loading:0`, then requires the deployment's own smoke key (`colors:smoke`)
to read back — proving the set is *this* deployment's data, not merely a
valid RDB — and only then writes `<profile>/.colors-recovery-verified`
beside the sets. "The service answers" and "the service can be recovered"
are different claims; the marker is what lets automation tell them apart.

What was **not** rehearsed: copying a set into a fresh host's data volume
and starting the live service from it. The documented path (stop Redis,
place `dump.rdb`, remove `appendonlydir/`, start with AOF on so Redis
rewrites the base from the loaded RDB) follows from the loading rule above
but was not executed on this build; say so in any runbook that repeats it.

## Honest RPO

A graceful restart loses at most the last second of acknowledged writes
(`appendfsync everysec`); the converge gate proves the key survives. Losing
the host loses everything since the newest **completed** set — the backup
interval, six hours here — and the monitor fails when the newest completed
set is older than `redis-backup-max-age-hours`. A monitor that measured the
newest *object* instead would be fooled by a half-uploaded set.

## Colors-specific notes

- ONCE's create matrix reads `:ssh_key_id` **with the underscore** from the
  map the package's `state-fn` returns. Normalizing that map to kebab-case
  before ONCE sees it makes the deployment's own provider key read as
  foreign, and the never-adopt rule refuses it ("already has an SSH key
  named … that is not in this deployment's state"). Paid for on the
  langfuse-multi-node build; the redis package adds `:vpc-ip` *beside*
  `:vpc_ip` and leaves the rest alone, and converge 2 here passed the
  preflight with the key in state.
- Ansible splits a `shell:` block before running it and counts quotes
  across comments: a lone apostrophe in a comment fails the play at load
  time. Quoting-heavy shell lives in installed scripts; the package's `bb
  syntax` runs `ansible-playbook --syntax-check` and `bash -n` on the
  rendered tree offline in a second. Not hit here because the gate ran
  before the first converge.
- `RestartCount` in `docker inspect` is cumulative for the container's
  life; a monitor threshold on the raw count flags a container that once
  crash-looped forever. Pair it with `.State.StartedAt`.

## References

- `references/pins.md` — the verified version set and its generation rules.
- `references/failure-catalogue.md` — symptom-indexed verbatim errors and
  log lines.
- `references/acceptance.md` — the gates and the rehearsal, what each one
  proves, and what a pass does not prove.
