---
name: neon-single-node
description: Everything a single-node self-hosted Neon (serverless Postgres) deployment needs that the docs and the dev docker-compose will not tell you - compute_ctl dying with a bare "Permission denied (os error 13)" on a root-owned spec, "File exists (os error 17)" when a volume sits on pgdata, the stale /tmp/.s.PGSQL.55433.lock that crash-loops every restart until the container is recreated, the /checkpoint API answering "compiled without testing APIs" on release images, remote_consistent_lsn reading 0/0 right after any restart, and Cloudflare R2 remote storage that works only once rclone stops trying to create the bucket (AccessDenied 403 on writes a scoped token should allow, NotImplemented 501 from rcat). Use whenever the user self-hosts Neon - pageserver, safekeeper, storage broker, compute node - on one machine, wires Neon to S3-compatible or R2 storage, asks how durable a single Neon node really is, or hits any symptom above. Full symptom index at the top of the body.
---

# Single-node self-hosted Neon

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim symptoms in `references/failure-catalogue.md`:

- compute_ctl prints only `Error: Permission denied (os error 13)` right
  after its build tag and the container restarts forever
- `could not start the compute node: File exists (os error 17)` plus
  `could not access the server configuration file ... postgresql.conf`
- `FATAL: lock file "/tmp/.s.PGSQL.55433.lock" already exists` after a
  container stop/start or a host reboot — compute crash-loops until recreated
- `Failed to create tenants root dir at '/data/.neon/tenants' … Permission
  denied (os error 13)` from the pageserver
- `{"msg":"\"Cannot run timeline checkpoint because pageserver was compiled
  without testing APIs\""}`
- rclone against R2: `AccessDenied: Access Denied status code: 403` on
  writes a bucket-scoped token should allow, or
  `NotImplemented: Not Implemented status code: 501` from `rcat`
- `remote_consistent_lsn` is `0/0` right after a pageserver restart or a
  fresh attach, and someone concludes uploads are broken
- Ansible: `Error loading tasks: failed at splitting arguments, either an
  unbalanced jinja2 block or quotes` on a shell task that looks fine
- an `ssh -f` tunnel probe that "succeeds" and then gets
  `Connection refused` — the runner blocked until the tunnel expired
- Ubuntu 24.04: `No package matching 'awscli' is available`

Neon separates Postgres into a stateless compute (`compute_ctl` + Postgres),
a pageserver (the storage engine, backed by S3), safekeepers (WAL quorum),
and a storage broker. Upstream's `docker-compose/` gets that *running* — as a
development fixture: MinIO, three colocated safekeepers, trust auth, floating
`latest` tags, a committed JWKS keypair, `fsync=off`, and a `compute.sh`
whose `--dev` flag is lost to a missing line continuation. The gap this skill
covers is the distance between that and a deployment whose durability claims
were proven: one storage image + one compute image on one host, Cloudflare R2
as the remote storage, credentialed auth, and recovery that was rehearsed,
not assumed. That distance was measured on a live build — twelve converges
against the real platform, a three-round adversarial plan review, a two-round
post-build inspection, and recovery/rotation rehearsals on the live host.

Everything here was verified against a running deployment unless it says
otherwise. Where this skill contradicts the docs, the pinned source or a live
probe is the authority, and the entry says which.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/neon`](https://github.com/getcolors/neon) Package Skill —
compose, pageserver/compute configuration, the tenant/timeline bootstrap,
the smoke gates, rotation — under
`green/src/resources/io/github/getcolors/neon/tools/`, covered by that
repo's tests, golden fixtures, and three-colour parity, and consumed by the
[`neon-vultr`](https://github.com/getcolors/neon-vultr) deployment. This
skill carries no copies of them, per the Context Skill Standard's
no-second-copy rule. Read the templates there; read *why they are shaped
that way* here. Outside the Colors ecosystem the topology and traps below
transfer wholesale — only the OpenTofu/Ansible packaging is local.

## Topology that survived

One host, four containers: `storage_broker` (:50051), `pageserver`
(:9898 HTTP, :6400 page service), **one** `safekeeper` (:7676, :5454), and a
`compute-node-v17` running `compute_ctl`. Everything binds loopback; the
supported client path is an SSH tunnel. Three safekeepers on one host is
redundancy theater — commit acknowledgement needs that disk either way.

- **The R2 prefix plus the tenant/timeline ids ARE the database.** Fix the
  32-hex tenant and timeline ids in desired state; the bootstrap then
  reconciles (read-before-write, 409 tolerated, postcondition reads) instead
  of minting identities, and recovery becomes describable.
- **Pageserver runs as uid 1000 (`neon`)** and must own its data directory.
  Its config dir *is* its data dir (`pageserver.toml` + `identity.toml` in
  `/data/.neon/`); a bind mount there makes wiping `tenants/` for recovery
  trivial.
- **Compute is a disposable projection.** No volume on pgdata (compute_ctl
  must create it itself), a tmpfs on `/tmp` (the socket-lock trap), and a
  recreate-only doctrine: `docker compose up -d --force-recreate compute`,
  never stop/start — recreate is also how spec changes apply, because
  compute_ctl reconciles roles at startup only.
- **The compute spec is the auth system.** `cluster.roles[].encrypted_password`
  accepts a SCRAM-SHA-256 verifier string directly (`SCRAM-SHA-256$4096:…`,
  pbkdf2/hmac — verified live, password auth works over the published port);
  `cluster.databases[] {name, owner}` creates the database. compute_ctl
  renders pg_hba itself: container-loopback trust (how `-C
  postgresql://cloud_admin@localhost:55433/postgres` connects), everything
  else `host all all all md5` — and host-side connections arrive from the
  Docker bridge gateway, so they DO hit the password rule. Generate
  verifiers once and store them: the salt is random, so regenerating per
  converge makes the spec non-deterministic and recreates compute every run.
- **Rotation = new verifier in the spec + recreate**, proven live: the old
  password stops working, the new works. Stage everything before the live
  checks, commit as adjacent renames, journal the new plaintext at a fixed
  path across the one window renames cannot close, and keep the stored
  verifier in sync or the next converge silently un-rotates.
- **R2 works as Neon remote storage** — pageserver `remote_storage=
  { endpoint=…, bucket_name=…, bucket_region='auto', prefix_in_bucket=… }`,
  safekeeper `--remote-storage={…}`, credentials via
  AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env. Verified: layer objects,
  `initdb.tar.zst`, offloaded 16MB WAL segments, and a full re-attach that
  read the data back.
- **Guard shared buckets with two-phase ownership markers** (`.colors-init`
  before any data, `.colors-ready` only after gates pass) plus a generation
  counter object persisted *before* each attach — pageserver generations
  must rise across re-attaches of the same tenant, and a counter that trails
  the attach can hand out a stale generation after a crash. Emptiness counts
  as absence and every marker write is verified by read-back: a 0-byte
  marker satisfies a bare existence check forever.

## Durability, measured

The honest single-node RPO surprised the build twice; get it right:

- The safekeeper offloads **closed** segments (force with `pg_switch_wal()`
  — the `/v1/.../checkpoint` API is a testing-build feature absent from
  release images). The pageserver uploads layers on its own checkpoint
  cadence; `remote_consistent_lsn` was observed advancing while running and
  **reads 0/0 after any restart or fresh attach** — never gate on it
  post-restart.
- **Losing storage-tier local state on a surviving host loses nothing**:
  a wiped pageserver re-attaches from R2 at the next generation and the
  live safekeeper replays WAL to the latest LSN (rehearsed: 38MB wiped,
  everything back). A wiped safekeeper volume also rejoins: the walproposer
  bootstraps it from the compute basebackup (rehearsed).
- **A fresh safekeeper cannot serve its offloaded WAL back.** Full host loss
  therefore recovers what the pageserver had uploaded — the RPO is the
  activity since its last checkpoint upload, minutes not seconds. Say this
  in your docs instead of implying the WAL backup closes the gap.
- Moving buckets is a migration, not an edit: quiesce compute, drain uploads
  (watch `remote_consistent_lsn` catch `last_record_lsn` on the *running*
  pageserver), stop storage, `rclone sync` the prefix, verify, re-point.

## Release archaeology

Upstream stopped cutting versioned releases in July 2025 and moved to
untagged CI pushes; Docker Hub is stale and ghcr.io is canonical. The last
deliberate pairing is storage `release-9129` + compute `release-compute-9073`
(the trains version independently — see `references/pins.md`). Read
`docker-compose/` **at the pinned tag, not main**: a year of drift separates
them, including the compute config layout.

## References

- `references/pins.md` — the verified version set and its generation rules.
- `references/failure-catalogue.md` — symptom-indexed verbatim errors.
- `references/acceptance.md` — the gates and rehearsals that make the
  durability claims checkable, including the negative-space auth gates.
