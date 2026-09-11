---
name: redis-single-node
description: 'What a single-node Redis 7 deployment needs beyond the docs, verified live on Vultr and AWS - a restored dump.rdb that loads ZERO keys because the instance started with appendonly yes and no appendonlydir/ ("Creating AOF base file appendonly.aof.1.base.rdb on server start"), redis-cli refusals ("NOAUTH Authentication required.", "WRONGPASS") that exit 0 so exit-code gates pass, a minutes-old host UNREACHABLE (kex_exchange_identification reset) after unattended-upgrades restarted sshd, Docker-published ports that bypass ufw, backups streamed with `redis-cli --rdb -`, backup sets that count only once a .complete marker reads back, and, on AWS, OpenTofu 1.12 "Error: No state file was found" failing a create, "Permission denied" reading the password because the AMI logs in as ubuntu, an S3 encryption rule planning "1 to change" forever, and "managed storage credentials unavailable" on delete. Use for self-hosted Redis on one machine with Docker Compose and S3-compatible backups. Full symptom index in the body.'
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
- a play on a host booted minutes ago fails `UNREACHABLE` with
  `kex_exchange_identification: read: Connection reset by peer` — and the
  host is fine a minute later
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
- AWS: a create fails with `managed S3 storage failed; inspect bucket
  ownership, state access, and AWS permissions` after the instance exists,
  because OpenTofu 1.12 prints `Error: No state file was found` where 1.11
  printed `No state file was found!`
- AWS: `acceptance: could not read the generated Redis password over ssh`,
  or `Permission denied` from `ssh <alias> cat /etc/redis/secrets/password`
  and from `ssh <alias> redis-status`, because the AMI logs in as `ubuntu`
- AWS: `tofu plan -detailed-exitcode` on the storage stage exits 2 after
  every converge, `Plan: 0 to add, 1 to change, 0 to destroy.` on
  `aws_s3_bucket_server_side_encryption_configuration`
- AWS: an authorized `delete` stops at the cleanup play with `managed
  storage credentials unavailable` and destroys nothing
- AWS: a `tofu plan` run from `.colors/<profile>/redis-infrastructure/`
  says `aws_key_pair.machine must be replaced`; that tree is the build
  render, not evidence

Redis is easy to run and easy to run wrong in ways nothing reports. The
gap this skill covers is between a container that answers `PONG` and a
deployment whose claims were proven: which addresses actually listen, that
a refusal is a refusal, that a restart keeps the data, that a backup set is
a backup set, and that a restore restores. That distance was measured on
two live builds.

The first was the `redis-vultr` deployment on 2026-09-03: two converges
(the first through the pinned launcher passed on its first run; the second
was the idempotence proof), one recovery rehearsal, one deliberate negative
probe of the AOF/RDB loading rule, and two authorized deletes — the first
failed on a trap the catalogue now carries, the second removed everything.

The second was the `redis-aws` deployment on 2026-09-11, the same package
on AWS with two deployment-owned S3 buckets: five creates (two failed on
package bugs the catalogue now carries, then three passed, the last two
being the idempotence proof), `describe` twice, one recovery rehearsal, a
refused delete, an authorized delete that failed on a third trap, an
authorized delete that removed everything, and a repeat delete that exited
0 in five seconds. Four traps were paid for and each was fixed at the
source in `getcolors/redis` before the verb ran again.

Everything here was verified against one of those running deployments
unless it says otherwise, and each claim names its build where the two
differ. Entries carried from sibling builds name the build that paid for
them.

## Tri-colour provenance

The companion package is now tri-colour (green, red, blue), and
`scripts/parity.sh` enforces that the three render every fixture byte for
byte the same. The AWS build ran the green launcher end to end. The red
and blue ports render the same trees and pass their own suites, and the
fourth fix was landed in all three colours with a test each; their live
verification on AWS is pending as of this update. The red and blue payloads
have been published since `daa6811` and are installed in the `redis-aws`
deployment, but had not been live-run from it when this was written.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/redis`](https://github.com/getcolors/redis) Package Skill —
the Compose file, the convergence play, the smoke gate, the backup and
restore-check scripts, the rehearsal play, and the managed-storage stage —
under `green/src/resources/io/github/getcolors/redis/tools/` (the red and
blue resource trees are byte-identical copies), covered by that repo's
tests, golden fixtures, offline syntax gate and parity script, and
consumed by the
[`redis-vultr`](https://github.com/getcolors/redis-vultr) and
[`redis-aws`](https://github.com/getcolors/redis-aws) deployments. The
latter carries the AWS build's `verification.md` and `evidence/` tree.
This skill carries no copies of any of it, per the Context Skill
Standard's no-second-copy rule. Read the templates there; read *why they
are shaped that way* here. Outside the Colors ecosystem the doctrine
transfers wholesale — only the OpenTofu/Ansible packaging is local.

## Topology that survived

One instance, one Docker Compose service running `redis:7.2.16` by digest,
a provider firewall admitting 22 alone, and an SSH tunnel as the supported
client path. No DNS, no public port. On Vultr that was a `vc2-1c-2gb`
(Ubuntu 24.04) in its own VPC; on AWS a `t3.small` (Ubuntu 24.04.4 from
`ami-025d99823a4caad37`) in a VPC, subnet and security group that
`colors-compute` owns because an EC2 instance cannot exist without them.

- **Exposure is decided by what Compose publishes, not by `bind`.** Inside
  the container Redis binds `0.0.0.0`; the host bindings in the Compose
  `ports:` are the whole of what can reach it, and the gate asks the
  kernel, not the config. On the 2026-09-03 Vultr build `ss -ltnH "sport
  = :6379"` listed exactly `10.60.0.3:6379` and `127.0.0.1:6379`, a
  loopback binding and a VPC binding. The package has since dropped the
  VPC binding when it adopted the Compute Provider Standard: a single-node
  package creates no private network and nothing ever connected to that
  address. On the 2026-09-11 AWS build the kernel listed exactly
  `127.0.0.1:6379`, and the gate now expects that one line. In both builds
  a bounded TCP connect from the workstation to the public address failed
  while the tunnel round-trip succeeded.
- **No address reaches the rendered tree.** The Compose file publishes on
  `127.0.0.1` alone, so no run-time address has to reach it; the node's
  `vpc_ip` that `colors-compute` reports on AWS is read by nothing in the
  package.
- **The password is born on the host, once**
  (`/etc/redis/secrets/password`, `creates:`), lives in `redis.conf`
  readable by uid 999 alone, and is handed to `redis-cli` through
  `REDISCLI_AUTH` — `docker compose exec -T -e REDISCLI_AUTH=… redis
  redis-cli` — never on a command line, never in the container
  environment. Reading it from the workstation is `ssh <alias> sudo -n cat
  /etc/redis/secrets/password`: the AWS AMI logs in as `ubuntu`, the Vultr
  and DigitalOcean images as root, and the `sudo -n` form works on both.
- **`maxmemory-policy noeviction` and `appendfsync everysec`** are asserted
  on every converge by `CONFIG GET` against the running server, not
  assumed from the file. A queue whose jobs can be evicted is a queue that
  loses jobs silently.
- **ufw is left as the image ships it.** Vultr's image ships it enabled
  with 22 alone; the AWS AMI ships it inactive, and the play does not turn
  it on. Docker's published ports bypass ufw through the DOCKER chain
  either way (verified on the langfuse-multi-node build), so the loopback
  binding and the provider firewall (a Vultr firewall group, an AWS
  security group with ingress 22/tcp alone) are what bound exposure, and
  the acceptance proves the public address is closed rather than trusting
  either layer.

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
  neon-single-node build, where each flag was paid for; the Vultr build ran
  with them from the start and did not re-test without.
- **rclone against native S3 keeps the same flags.** `r2-env.sh` switches
  the remote's provider from `Cloudflare` to `AWS` when the endpoint is an
  `amazonaws.com` host, so rclone signs for S3; `no_check_bucket` and
  `no_head` stay on. Five completed sets and the recovery marker landed in
  the AWS bucket that way, each read back with the AWS CLI. Whether the
  flags are needed on S3 was not tested: the build never ran without them.

## A deployment-owned bucket on AWS

On Vultr the backup bucket is somebody else's: an operator-made R2 bucket
and a bucket-scoped token exported as `COLORS_PAR_REDIS_BACKUP_R2_*`. On
AWS with `redis-storage-managed: true` the package owns it. A separate
`redis-storage` OpenTofu stage creates the bucket with every public-access
block on, AES256 default encryption and `force_destroy`, plus one IAM user
(`<profile>-storage-backup`) with an inline policy scoped to that bucket
and one access key. The key pair is a sensitive stage output, never a
template value: the package reads it back from state and hands it to
`ansible-playbook` as the same `COLORS_PAR_REDIS_BACKUP_R2_ACCESS_KEY_ID`
and `_SECRET_ACCESS_KEY` an operator would export, so the play's
`lookup('env', …)` expressions do not know the difference. The OpenTofu
state bucket is managed too (`s3-bucket-mode: managed`), created by
`colors-compute` on the first create and finalized last on delete.

Verified 2026-09-11: after the first passing converge the bucket carried
`colors:profile` and `colors:owner=redis-storage` tags, all four
public-access blocks, an AES256 rule, one active key on the scoped user,
and two completed sets; the state bucket held the compute coordination
record, the shared and node states, and the storage state.

- **The delete order is cleanup play, `~/.ssh/config` block, compute,
  backup bucket, state bucket.** The bucket outlives the machine the way
  the machine keypair does, so the last backup timer run cannot fail
  against a missing bucket, and the state bucket goes last because every
  other stage's state lives in it. After the authorized delete every
  resource id from the create answered `NotFound`, `head-bucket` was 404 on
  both buckets, and the workstation had no alias block and no key files.
- **A repeat delete exits 0.** Inspection reports the compute absent and
  the finalizer proves the managed backend is gone: 5 seconds, no provider
  writes.
- **The bucket's contents go with the deployment.** A backup set in a
  deployment-owned bucket is destroyed with the deployment: `force_destroy`
  empties the bucket on delete, and nothing copies the sets out first. The
  explicit, override-guarded `delete` is the authorization boundary for
  that loss. A backup that must outlive its deployment belongs in a bucket
  the deployment does not own, which is the Vultr shape.

## The restore doctrine, and the trap it exists for

**A Redis 7 started with `appendonly yes` and no `appendonlydir/` beside
`dump.rdb` loads nothing.** It creates an empty AOF base and increment file
on start, logs `Creating AOF base file appendonly.aof.1.base.rdb on server
start`, answers `PONG`, and reports `DBSIZE` 0 — the RDB is never read.
Reproduced deliberately on the live Vultr host with the just-restored
288-byte set (2 keys under `--appendonly no`, 0 keys under `--appendonly
yes`).

So the rehearsal restores into a **scratch** container of the pinned image
with `--appendonly no --save "" --dir /data --dbfilename dump.rdb`, no
published port, no password, reached only through `docker exec`, and
removed by an `EXIT` trap whatever happened. It waits for `PONG` and
`loading:0`, then requires the deployment's own smoke key (`colors:smoke`)
to read back — proving the set is *this* deployment's data, not merely a
valid RDB — and only then writes `<profile>/.colors-recovery-verified`
beside the sets. "The service answers" and "the service can be recovered"
are different claims; the marker is what lets automation tell them apart.
The AWS rehearsal wrote `redis-aws set=20260911T041136Z
at=20260911T041148Z`, read back as a 50-byte AES256 object.

What was **not** rehearsed on either build: copying a set into a fresh
host's data volume and starting the live service from it. The documented
path (stop Redis, place `dump.rdb`, remove `appendonlydir/`, start with
AOF on so Redis rewrites the base from the loaded RDB) follows from the
loading rule above but was not executed; say so in any runbook that
repeats it.

## Honest RPO

A graceful restart loses at most the last second of acknowledged writes
(`appendfsync everysec`); the converge gate proves the key survives. Losing
the host loses everything since the newest **completed** set — the backup
interval, six hours on both builds — and the monitor fails when the newest
completed set is older than `redis-backup-max-age-hours`. A monitor that
measured the newest *object* instead would be fooled by a half-uploaded
set. Deleting a deployment that owns its bucket loses every set with it;
that is by design, and `delete` is the authorization for it.

## A fresh Ubuntu 24.04 host upgrades itself minutes after boot

`apt-daily-upgrade.timer` fired six minutes after first boot on the Vultr
build, and `unattended-upgrade` upgraded sixty packages over the next
three minutes. Two of them — libpam and libssl — restart sshd, and the
delete's cleanup play opened its first connection inside that second:
`kex_exchange_identification: read: Connection reset by peer`, host
`UNREACHABLE`, play failed, destroy never ran (correctly leaving the key
and the config block). The earlier converges and the rehearsal had merely
missed the window. Every play now runs with `[ssh_connection] retries =
3` and a `wait_for_connection` first; a single-attempt connection on a
young host is a coin toss. The AWS build ran with both from the start and
never met the window; whether the AMI's timer fires as early was not
measured.

## Four traps the AWS build paid for

Each has a verbatim entry in the catalogue and a fix with a test in
`getcolors/redis`; the short version:

1. **OpenTofu changed a message.** 1.11 says `No state file was found!`;
   1.12.5 says `Error: No state file was found`. A preflight that read an
   empty managed-storage state by matching the 1.11 string threw on 1.12
   and failed the first create after the instance existed. Match the
   shared phrase from `-no-color` output, and keep failing closed on
   anything else: a failed state read never means absence.
2. **The AMI logs in as `ubuntu`.** Every root-only read from the
   workstation (`cat /etc/redis/secrets/password`, the installed
   `redis-status` reading `/etc/colors/backup-r2.env` and the Docker
   socket) was refused. The fix is `cat … || sudo -n cat …` for the
   password and a `[ "$(id -u)" -eq 0 ] || exec sudo -n "$0" "$@"` guard
   in the helper, not looser file modes.
3. **Provider 6.31 reports two encryption attributes you did not set.**
   A new bucket comes back with `blocked_encryption_types = ["SSE-C"]` and
   `bucket_key_enabled = false`; a rule that declares neither is rewritten
   in place on every apply, so the idempotence proof fails with exit 2
   forever. Declare both.
4. **The delete DAG reads the storage pair after the play that would use
   it.** The cleanup play only runs `docker compose down` and reads no
   backup variable; asking `run-play` for the managed credentials there
   threw `managed storage credentials unavailable` before anything was
   destroyed. Run the cleanup play without the pair.

## Colors-specific notes

- ONCE's create matrix reads `:ssh_key_id` **with the underscore** from the
  map the package's `state-fn` returns. Normalizing that map to kebab-case
  before ONCE sees it makes the deployment's own provider key read as
  foreign, and the never-adopt rule refuses it ("already has an SSH key
  named … that is not in this deployment's state"). Paid for on the
  langfuse-multi-node build and re-proven on the 2026-09-03 Vultr build,
  when the redis package still ran on ONCE's matrix. The package now
  delegates compute, state and the machine keypair to `colors-compute`;
  the note stays for packages that still carry a `state-fn`.
- The launcher's create log ends at the failing step's one-line message
  with no tool output; a storage-stage exception is swallowed into
  `managed S3 storage failed; …`. Reproduce by hand in
  `.colors/<profile>/redis-storage` (`tofu state list`, `aws s3api
  head-bucket`) rather than guessing from the log.
- Ansible splits a `shell:` block before running it and counts quotes
  across comments: a lone apostrophe in a comment fails the play at load
  time. Quoting-heavy shell lives in installed scripts; the package's `bb
  syntax` runs `ansible-playbook --syntax-check` and `bash -n` on the
  rendered tree offline in a second. Not hit on either build because the
  gate ran before the first converge.
- `RestartCount` in `docker inspect` is cumulative for the container's
  life; a monitor threshold on the raw count flags a container that once
  crash-looped forever. Pair it with `.State.StartedAt`.

## References

- `references/pins.md` — the verified version sets and their generation
  rules.
- `references/failure-catalogue.md` — symptom-indexed verbatim errors and
  log lines.
- `references/acceptance.md` — the gates and the rehearsal, what each one
  proves, and what a pass does not prove.
