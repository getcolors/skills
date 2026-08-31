# Pins

## The verified-good set

Running together on a Vultr `vc2-4c-8gb` (Ubuntu 24.04, os id 2284) with
every acceptance gate passing, plus the recovery and rotation rehearsals.
**Verified 2026-08-31.**

| Component | Pin |
|---|---|
| storage image (pageserver, safekeeper, storage_broker) | `ghcr.io/neondatabase/neon:release-9129@sha256:166022a72bf9983eba96d061d794f4740edbd4c3301e66202c1180acce9a323c` |
| compute image (Postgres 17 + compute_ctl) | `ghcr.io/neondatabase/compute-node-v17:release-compute-9073@sha256:ed6a613231d7026b4df8b00563444b9f33745370a3b3f0a2183e723f460ba974` |
| Postgres major | 17 (must agree with the compute image name) |
| host packages | Ubuntu 24.04 apt: `docker.io`, `docker-compose-v2`, `postgresql-client`, `rclone` (v1.60.1-DEV — the rclone flags below exist because of this vintage), `jq`, `openssl`, `python3` |

## The rules that generated it

The specific versions will age out; these constraints are what matter.

### ghcr.io is canonical; Docker Hub is stale

Upstream cut its last versioned releases in July 2025 and then moved to
untagged continuous deployment (CI-run-id tags). Docker Hub's newest real
release tag predates that switch. Resolve tags and digests against
`ghcr.io/neondatabase/*`.

### The trains version independently — pin the last deliberate pairing

Storage releases (`release-NNNN`), compute releases (`release-compute-NNNN`),
and proxy releases are separate trains with separate numbering. There is no
shared release number to match. `release-9129` (storage, 2025-07-25) and
`release-compute-9073` (compute, 2025-07-28) are the final tags of each
train — the last pairing upstream deliberately shipped. Move both together
or neither, and re-read `docker-compose/` at the new storage tag when you
do: the compose tree on `main` is a year ahead of the release images and its
compute config layout differs.

### Digest-pin both

Upstream publishes floating tags (`latest` on ghcr resolves to a CI build,
not to `release-9129`). The companion package's validation requires
`tag@sha256:...` on both image keys for exactly this reason.

### Retest conditions

- Any storage-image bump: re-verify the R2 `remote_storage` config syntax,
  the `/v1/tenant/{id}/location_config` attach shape and generation
  semantics, and whether the release still lacks the testing `/checkpoint`
  API (the acceptance doctrine leans on `pg_switch_wal()` because of it).
- Any compute-image bump: re-verify the spec schema (`cluster.roles[]`
  accepting a SCRAM verifier in `encrypted_password`, `cluster.databases[]`),
  the rendered pg_hba shape, the pgdata-must-not-be-a-mountpoint behaviour,
  and the runtime uid (1000/postgres — the spec file ownership depends on it).
- An rclone newer than ~1.64 may not need `no_check_bucket`/`no_head` or the
  no-`rcat` rule; retest before dropping them.
