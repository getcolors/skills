# Failure catalogue

Symptom-indexed, verbatim where the error was verbatim. Every entry was hit
(or deliberately reproduced) on the live build at the pins in `pins.md`.

## `Error: Permission denied (os error 13)` — compute_ctl, nothing else

```
INFO compute build_tag: release-compute-9073
Error: Permission denied (os error 13)
```

The container restarts forever; no file is named. compute_ctl could not READ
its spec/config file. The compute container runs as `postgres` uid 1000, so
a root-owned `0600` spec — the natural result of rendering it with
root's umask — is invisible to it. Fix: `chown 1000:1000`, mode `0400`, and
enforce that on *every* path that touches the file: the converge render, the
unchanged branch of the render, rotation, and rotation's rollback. (The
rollback restoring a root-owned backup is how this was hit the second time.)

## `File exists (os error 17)` + missing postgresql.conf

```
ERROR could not start the compute node: File exists (os error 17)
PG:postgres: could not access the server configuration file
  "/var/db/postgres/compute/postgresql.conf": No such file or directory
```

A volume (or any pre-existing directory) sits on the pgdata path. compute_ctl
insists on creating pgdata itself; a root-owned mountpoint there fails the
boot. Remove the volume — compute local state is a disposable projection of
the storage tier, and mounting it buys nothing.

## `FATAL: lock file "/tmp/.s.PGSQL.55433.lock" already exists`

```
FATAL:  lock file "/tmp/.s.PGSQL.55433.lock" already exists
HINT:  Is another postmaster (PID 22) using socket file "/tmp/.s.PGSQL.55433"?
ERROR could not start the compute node: Postgres exited unexpectedly with code 1
```

After a container stop/start (or host reboot with `restart: unless-stopped`):
the writable layer keeps `/tmp`, the stale lock survives, and every
subsequent boot dies while compute_ctl loops init→failed. Two-part fix:
mount a **tmpfs on `/tmp`** so unattended restarts survive, and treat the
container as **recreate-only** (`docker compose up -d --force-recreate
compute`) — which is required anyway for spec changes to apply.

## Pageserver: `Failed to create tenants root dir … Permission denied`

```
Error: Failed to create tenants root dir at '/data/.neon/tenants'
Caused by: Permission denied (os error 13)
```

The storage image runs as `neon` uid 1000; a root-owned bind mount on
`/data/.neon/` blocks it. `chown 1000:1000` the host directory (and the
`pageserver.toml`/`identity.toml` you place inside it).

## `Cannot run timeline checkpoint because pageserver was compiled without testing APIs`

```
{"msg":"\"Cannot run timeline checkpoint because pageserver was compiled without testing APIs\""}
```

`PUT /v1/tenant/{t}/timeline/{tl}/checkpoint` is a testing-build feature;
release images do not have it. To force WAL to R2, close a segment with
`SELECT pg_switch_wal();` (superuser) — the safekeeper offloads closed
segments within seconds. Layer uploads cannot be forced at all on release
images; they follow the pageserver's checkpoint cadence.

## rclone → R2: `AccessDenied` on writes the token should allow

```
ERROR : .colors-init: Failed to copy: AccessDenied: Access Denied
	status code: 403, request id: , host id:
```

Reads work, tofu writes the same bucket with the same keys — but rclone
fails every upload. Old rclone (Ubuntu 24.04's 1.60) precedes the first
upload with a bucket check/create, and `CreateBucket` is denied for a
bucket-scoped R2 token; the surfaced error looks like a plain write denial.
Fix: `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`.

## rclone → R2: `NotImplemented: Not Implemented status code: 501`

`rclone rcat` (unknown-size streaming upload) is a 501 against R2 on this
rclone vintage, and `copyto` trips a 501 on its first attempt's post-upload
verification. Fix: never `rcat` — stage a known-size tmpfile and `copyto` —
plus `RCLONE_CONFIG_R2_NO_HEAD=true`. Configure rclone entirely from env
(`RCLONE_CONFIG_R2_TYPE=s3`, `PROVIDER=Cloudflare`, keys, `ENDPOINT`,
`REGION=auto`): no config file to manage or leak.

## `remote_consistent_lsn` is `0/0` — and it is not (necessarily) broken

Right after a pageserver restart or a fresh generation attach the metric
reads `0/0` even when R2 holds a complete, recoverable copy; it was observed
advancing (`0/0 → 0/8006A48`) only while the process ran. Never gate a
converge or a health check on it post-restart. Conversely, do not let an old
object satisfy an upload-health gate: require a NEW safekeeper segment
beyond a pre-`pg_switch_wal` listing baseline.

## Ansible: `failed at splitting arguments, either an unbalanced jinja2 block or quotes`

A `shell:` block task that is valid bash still fails to load when the block
contains an **odd number of apostrophes — in a comment**
(`# the container's postgres user`). Ansible's splitter counts quotes across
the whole block. Keep task comments apostrophe-free.

## The `ssh -f` tunnel that dies exactly when you use it

An acceptance probe: `ssh -f -o ExitOnForwardFailure=yes -L port:… host
sleep 45` "succeeds", then psql gets `Connection refused` — and the step
took suspiciously close to 45s. The daemonized ssh child inherits the
runner's stdout/stderr pipes; any runner that waits for the streams to close
blocks until the remote `sleep` exits, then proceeds against a dead tunnel.
Fix: wrap in `bash -c '… >/dev/null 2>&1'` so the child holds /dev/null.
Related: psql `-tAc` with multiple statements prints command tags
(`INSERT 0 1`) before the value — parse the last line.

## Ubuntu 24.04: `No package matching 'awscli' is available`

awscli v1 left the archive and v2 never entered it. Use rclone (see above)
or ship the AWS CLI yourself.

## A 0-byte ownership marker

An empty object satisfies `existence` checks forever while carrying no
ownership — and `rclone cat` on it exits 0, so a guard like
`if ! rclone cat …` never rewrites it. Treat emptiness as absence, verify
every marker write by read-back, and persist the generation counter *before*
the attach it covers (an interruption then burns a number instead of handing
a later recovery a stale generation).
