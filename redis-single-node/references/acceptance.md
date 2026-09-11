# Acceptance doctrine

What each gate checks, what its pass proves, and what it does not. All of
these ran on `redis-vultr` on 2026-09-03 and on `redis-aws` on 2026-09-11,
at the pins in `pins.md`. Where a gate changed between the builds the row
says so.

## On the host, every converge (`redis-smoke`)

| Gate | Checks | Proves |
|---|---|---|
| S1 round-trip | `SET colors:smoke <stamp>` answers `OK`; `GET` returns the stamp | the write path with the generated password |
| S2 configuration | `CONFIG GET maxmemory-policy` = `noeviction`, `appendonly` = `yes`, `appendfsync` = `everysec`; `INFO persistence` has `aof_enabled:1`; `INFO server` has `redis_version:7.2.` | the server runs what desired state says, not what a file says |
| S3 negatives | anonymous `PING` reply contains `NOAUTH`; wrong `REDISCLI_AUTH` reply contains `WRONGPASS` or `NOAUTH` and **not** `PONG` | the port is a gate, not an open door; replies are grepped because exit codes are 0 either way |
| S4 bind addresses | `ss -ltnH "sport = :<port>"` lists exactly `127.0.0.1:<port>`; a bounded connect to `<public-ip>:<port>` from the host fails | only loopback listens, asked of the kernel and not of Compose. On the 2026-09-03 Vultr build the expected list was `127.0.0.1:<port>` and `<vpc-ip>:<port>`; the package dropped the VPC binding when it adopted the Compute Provider Standard, and the AWS build passed with the one line |
| S5 restart persistence | `docker compose restart -t 30 redis`, wait for `PONG`, `GET colors:smoke` still returns the stamp, `aof_last_write_status:ok` | the append-only file keeps acknowledged writes across a graceful restart |

Then the play installs the timers and takes the **first backup set**
(`redis-backup`), which must print `complete`, and runs the monitor once
so `describe` has a result.

## From the workstation, every create (the acceptance step)

| Gate | Checks |
|---|---|
| A0 public port | `timeout 5 bash -c 'exec 3<>/dev/tcp/<public-ip>/<port>'` fails |
| A1 tunnel round-trip | `ssh -f -L <random>:127.0.0.1:<port> <profile> sleep 45` through the generated `~/.ssh/config` alias; `SET colors:operator <stamp>` → `OK`, `GET` → the stamp, with the password read over SSH (`cat … \|\| sudo -n cat …`, since the AWS AMI logs in as `ubuntu`) and passed as `REDISCLI_AUTH` through `env -i` |
| A2 anonymous | `PING` through the tunnel without a password → reply contains `NOAUTH` |
| A3 wrong password | `PING` with `REDISCLI_AUTH=not-the-password` → reply contains `WRONGPASS` or `NOAUTH`, never `PONG` |

A0 is what turns "bound to loopback" from a configuration into a claim: it
is the only probe that runs from outside the machine. On AWS the probe to
`54.227.190.72:6379` timed out (exit 124) while port 22 opened.

## Before the converge on AWS (the storage stage)

| Step | Checks |
|---|---|
| O1 ownership preflight | `tofu init`, then `tofu state list -no-color`: exit 0, or exit 1 with `No state file was found` (an empty stage); anything else fails closed. When the state does not record `aws_s3_bucket.application["backup"]` at the configured name, `aws s3api head-bucket` must fail with `404`/`Not Found`/`NoSuchBucket`: an existing or inaccessible bucket is refused, never adopted |
| O2 apply | the bucket, its public-access block, the AES256 rule with `blocked_encryption_types = ["SSE-C"]` and `bucket_key_enabled = false`, the IAM user, the inline policy and one access key |
| O3 no-change plan (operator-side idempotence proof) | `tofu plan -detailed-exitcode` in `.colors/<profile>/redis-storage` after a converge exits 0: `No changes. Your infrastructure matches the configuration.` |

O3 is the proof the third trap broke: at the pin before `dccd696` it
exited 2 with `Plan: 0 to add, 1 to change, 0 to destroy.` after every
converge.

## `rehearse` (the recovery rehearsal)

| Step | Checks |
|---|---|
| R1 fresh set | `redis-backup`: `redis-cli --rdb -` stream, `redis-check-rdb` inside the image, upload, size and sha256 read back, `.complete` written last and read back |
| R2 restore | `redis-restore-check`: newest completed set downloaded, sha256 matches the manifest, scratch container of the pinned image with `--appendonly no`, `PONG` and `loading:0`, `DBSIZE ≥ 1`, `colors:smoke` present |
| R3 marker | `<profile>/.colors-recovery-verified` = `<profile> set=<stamp> at=<stamp>`, verified by read-back |

Observed on Vultr: 18.7 s end to end; `restored 20260903T080104Z into a
scratch docker.io/library/redis:7.2.16@sha256:… (2 keys,
colors:smoke=20260903T075959Z)`. Observed on AWS: the rehearsal step took
18.0 s (38 s wall with the state load); set `20260911T041136Z`, 288
bytes, 2 keys; marker `redis-aws set=20260911T041136Z at=20260911T041148Z`
read back with the AWS CLI as a 50-byte AES256 object. On AWS the
rehearsal reads the storage pair back from the stage's state, because it
runs a play without converging the stage.

## `describe` and the monitor

`redis-monitor` runs every 15 minutes and writes
`/var/lib/colors/redis-monitor.json`; `describe` reads it over the alias
and exits non-zero when unreachable or unhealthy. Problems it reports:
no `PONG`; `aof_enabled` not 1; `aof_last_write_status` /
`aof_last_bgrewrite_status` not ok; Redis using ≥ 70 % of host memory;
≥ 5 restarts with the last start under 30 minutes ago; disk ≥ 80 %; the
newest **completed** set older than `redis-backup-max-age-hours`. The
monitor file is 0644, so `describe` needs no sudo on the `ubuntu` login;
`redis-status`, which reads root-only files, does.

## `delete` on AWS, and the second delete

| Step | Checks |
|---|---|
| D0 guard | a plain `delete` exits 2 at the start step with `compute destruction is protected; set COLORS_PAR_COMPUTE_PREVENT_DESTROY=false to delete`; the instance is still running afterwards |
| D1 order | with the one-run override: cleanup play (no credentials), `~/.ssh/config` block, compute, backup bucket, state bucket |
| D2 absence | every id from the create answers `NotFound` (instance `terminated`; VPC, subnet, internet gateway, security group, key pair, volume, IAM user); `head-bucket` 404 on both buckets; no `<profile>` block in `~/.ssh/config`, no `~/.ssh/<profile>` key files |
| D3 repeat | a second authorized `delete` exits 0: inspection reports the compute absent, the finalizer proves the managed backend gone; 5 s, no provider writes |

## What a pass does not prove

- **Private-network reachability.** The package publishes on loopback
  alone; nothing listens on the VPC address `colors-compute` reports on
  AWS, and no peer exists on either build. A future peer needs a second
  binding in the Compose `ports:` and a provider firewall rule, neither of
  which exists or was tested. (The 2026-09-03 Vultr build did bind the VPC
  address; nothing connected to it then either.)
- **Recovery onto a live host.** The rehearsal proves a set restores into
  a scratch instance and holds this deployment's data; copying it into a
  fresh host's volume was not executed on either build.
- **Idempotence of the smoke restart.** Every converge left the
  container's `CreatedAt` unchanged (no recreate: `03:49:09Z` across three
  AWS converges), but `StartedAt` moves on every converge because S5
  restarts Redis by design.
- **Compute-stage idempotence from `.colors/`.** `colors-compute` runs
  tofu in a private working directory it removes; the tree under
  `.colors/<profile>/redis-infrastructure/` is the build-time render with
  the placeholder public key, so a plan there proposes replacing the key
  pair and the instance and is not evidence. The proof is the unchanged
  instance id, key pair id, volume id and launch time across runs, and the
  storage stage's own no-change plan.
- **The rclone flags on native S3.** `no_check_bucket` and `no_head` were
  kept when the provider switched to `AWS`; the build never ran without
  them, so whether S3 needs them is unknown.
- **Red and blue beyond one pin.** Both launchers passed the same
  lifecycle and audits as green on 2026-09-11 at pin `ffb0777`; a later
  pin needs its own run in each colour, since the ports share templates
  but not code.
