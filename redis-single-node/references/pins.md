# Pins

## The verified-good set

Running together on a Vultr `vc2-1c-2gb` (Ubuntu 24.04.4 LTS, os id 2284,
kernel 6.8.0-138-generic) with every converge gate, the workstation-side
acceptance and the recovery rehearsal passing. **Verified 2026-09-03**
(`redis-vultr`, package pin `getcolors/redis@9616d40`).

| Component | Pin |
|---|---|
| Redis image | `docker.io/library/redis:7.2.16@sha256:74566c6910d13ae61e7ce73ebd3127438a1fe805b309b097c323142719ec8a5b` (server reports `redis_version:7.2.16`) |
| Docker | 29.1.3 (`docker.io` 29.1.3-0ubuntu3~24.04.2, Ubuntu apt) |
| Docker Compose | 2.40.3 (`docker-compose-v2` 2.40.3+ds1-0ubuntu1~24.04.1, Ubuntu apt) |
| rclone | v1.60.1-DEV (Ubuntu apt — the R2 flags exist because of this vintage) |
| ufw | 0.36.2, as the image ships it: enabled, 22/tcp only, untouched |
| host packages | `docker.io`, `docker-compose-v2`, `ca-certificates`, `curl`, `jq`, `openssl`, `python3`, `rclone` |
| workstation | `redis-cli` 8.8.0 (nixpkgs `redis`) driving the tunnel acceptance against the 7.2.16 server |
| Colors | green `ceb4159`, ONCE `759eb03` (never below `bc06f2f`, where the machine keypair moved into `~/.ssh`) |

Backup sets from this build: `langfuse-backup/redis-vultr/redis/{20260903T080013Z,20260903T080104Z,…}/`,
288-byte RDBs with `dbsize=2`; recovery marker
`redis-vultr set=20260903T080104Z at=20260903T080120Z`.

## The rules that generated it

### Digest-pin the image

Docker Hub republishes the `7.2` and `7.2.16` tags whenever the base image
is rebuilt, so a tag alone does not pin bytes. The companion package's
validator requires `tag@sha256:…` on `redis-image` for this reason. (Rule,
not measured on this build: no republish happened during it.)

### Stay on the 7.x AOF/RDB semantics you tested

The restore doctrine (`--appendonly no` for the scratch; AOF-on loads only
the AOF manifest) and the backup stream (`redis-cli --rdb -`, `REPLCONF
rdb-only 1`, diskless EOF marker) were verified on 7.2.16. Redis 8 ships a
different licence, and its `redis-cli --rdb` and multi-part AOF behaviour
were not tested here.

### Ubuntu's Docker and Compose, not Docker's apt repository

`docker.io` + `docker-compose-v2` from Ubuntu 24.04 are what the play
installs and what every gate ran on. `docker compose restart -t 30`,
`docker compose exec -T -e VAR=…`, and `docker compose ps -q` behaved as
documented on 2.40.3.

### Retest conditions

- Any host image change: confirm whether unattended-upgrades still runs
  minutes after first boot and restarts sshd; the connection retries stay
  either way, but the catalogue entry's timing claim is image-specific.

- Any `redis-image` bump: re-run the negative probe (AOF on, no
  `appendonlydir/`, expect 0 keys) — if a future major loads `dump.rdb` in
  that state, the scratch doctrine is merely redundant, but the catalogue
  entry becomes wrong. Re-check that `redis-cli --rdb -` still streams
  diskless with an EOF marker and that `redis-check-rdb` still ships in
  the image.
- Any rclone newer than ~1.64: `no_check_bucket`/`no_head` and the
  no-`rcat` rule may be unnecessary; retest before dropping them (carried
  from neon-single-node).
- A Docker that stops publishing on a specific host address, or a Vultr
  image that ships ufw disabled: re-run the listener gate and the
  public-port probe before trusting the exposure claim.
