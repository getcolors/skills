# Acceptance doctrine

What each gate checks, what its pass proves, and what it does not. All of
these ran on `redis-vultr` on 2026-09-03 at the pins in `pins.md`.

## On the host, every converge (`redis-smoke`)

| Gate | Checks | Proves |
|---|---|---|
| S1 round-trip | `SET colors:smoke <stamp>` answers `OK`; `GET` returns the stamp | the write path with the generated password |
| S2 configuration | `CONFIG GET maxmemory-policy` = `noeviction`, `appendonly` = `yes`, `appendfsync` = `everysec`; `INFO persistence` has `aof_enabled:1`; `INFO server` has `redis_version:7.2.` | the server runs what desired state says, not what a file says |
| S3 negatives | anonymous `PING` reply contains `NOAUTH`; wrong `REDISCLI_AUTH` reply contains `WRONGPASS` or `NOAUTH` and **not** `PONG` | the port is a gate, not an open door; replies are grepped because exit codes are 0 either way |
| S4 bind addresses | `ss -ltnH "sport = :<port>"` lists exactly `127.0.0.1:<port>` and `<vpc-ip>:<port>`; a bounded connect to `<public-ip>:<port>` from the host fails | only loopback and the VPC listen — asked of the kernel, not of Compose |
| S5 restart persistence | `docker compose restart -t 30 redis`, wait for `PONG`, `GET colors:smoke` still returns the stamp, `aof_last_write_status:ok` | the append-only file keeps acknowledged writes across a graceful restart |

Then the play installs the timers and takes the **first backup set**
(`redis-backup`), which must print `complete`, and runs the monitor once
so `describe` has a result.

## From the workstation, every create (the acceptance step)

| Gate | Checks |
|---|---|
| A0 public port | `timeout 5 bash -c 'exec 3<>/dev/tcp/<public-ip>/<port>'` fails |
| A1 tunnel round-trip | `ssh -f -L <random>:127.0.0.1:<port> <profile> sleep 45` through the generated `~/.ssh/config` alias; `SET colors:operator <stamp>` → `OK`, `GET` → the stamp, with the password read over SSH and passed as `REDISCLI_AUTH` through `env -i` |
| A2 anonymous | `PING` through the tunnel without a password → reply contains `NOAUTH` |
| A3 wrong password | `PING` with `REDISCLI_AUTH=not-the-password` → reply contains `WRONGPASS` or `NOAUTH`, never `PONG` |

A0 is what turns "bound to loopback and the VPC" from a configuration
into a claim: it is the only probe that runs from outside the machine.

## `rehearse` (the recovery rehearsal)

| Step | Checks |
|---|---|
| R1 fresh set | `redis-backup`: `redis-cli --rdb -` stream, `redis-check-rdb` inside the image, upload, size and sha256 read back, `.complete` written last and read back |
| R2 restore | `redis-restore-check`: newest completed set downloaded, sha256 matches the manifest, scratch container of the pinned image with `--appendonly no`, `PONG` and `loading:0`, `DBSIZE ≥ 1`, `colors:smoke` present |
| R3 marker | `<profile>/.colors-recovery-verified` = `<profile> set=<stamp> at=<stamp>`, verified by read-back |

Observed: 18.7 s end to end; `restored 20260903T080104Z into a scratch
docker.io/library/redis:7.2.16@sha256:… (2 keys,
colors:smoke=20260903T075959Z)`.

## `describe` and the monitor

`redis-monitor` runs every 15 minutes and writes
`/var/lib/colors/redis-monitor.json`; `describe` reads it over the alias
and exits non-zero when unreachable or unhealthy. Problems it reports:
no `PONG`; `aof_enabled` not 1; `aof_last_write_status` /
`aof_last_bgrewrite_status` not ok; Redis using ≥ 70 % of host memory;
≥ 5 restarts with the last start under 30 minutes ago; disk ≥ 80 %; the
newest **completed** set older than `redis-backup-max-age-hours`.

## What a pass does not prove

- **VPC reachability.** No peer exists on the VPC, so nothing connected to
  `<vpc-ip>:<port>`; only the listener list proves the binding. A future
  peer also needs a `/32` rule in the Vultr firewall group, which filters
  the private interface too (langfuse-multi-node).
- **Recovery onto a live host.** The rehearsal proves a set restores into
  a scratch instance and holds this deployment's data; copying it into a
  fresh host's volume was not executed.
- **Idempotence of the smoke restart.** Converge 2 left the container's
  `CreatedAt` unchanged (no recreate), but `StartedAt` moves on every
  converge because S5 restarts Redis by design.
