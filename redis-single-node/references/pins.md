# Pins

Two verified-good sets, one per build. The Vultr set is the 2026-09-03
original; the AWS set is the 2026-09-11 second build of the same package
after it went tri-colour and adopted the Compute Provider Standard. Neither
replaces the other.

## The verified-good set: Vultr

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
| Colors | green `ceb4159`, ONCE `759eb03` (never below `bc06f2f`, where the machine keypair moved into `~/.ssh`); the package has since replaced its ONCE dependency with `colors-compute`, see the AWS set |

Backup sets from this build: `langfuse-backup/redis-vultr/redis/{20260903T080013Z,20260903T080104Z,…}/`,
288-byte RDBs with `dbsize=2`; recovery marker
`redis-vultr set=20260903T080104Z at=20260903T080120Z`.

## The verified-good set: AWS

Running on one `t3.small` in `us-east-1a` with every converge gate, the
workstation-side acceptance, the recovery rehearsal, the storage-stage
no-change plan, an authorized delete and a repeat delete passing.
**Verified 2026-09-11** (`redis-aws`, AWS account 251213589273; the last
live-verified package pin is `getcolors/redis@ffb0777`, stamped into the
three launchers by `7ce215e`; the deployment's `skills-lock.json` records
all three payloads from that publication). The green launcher ran every
verb; see `SKILL.md` for the red and blue status.

| Component | Pin |
|---|---|
| Redis image | unchanged: `docker.io/library/redis:7.2.16@sha256:74566c6910d13ae61e7ce73ebd3127438a1fe805b309b097c323142719ec8a5b`; the manifest reports `redis_version=7.2.16` |
| Green SDK | `3f33f5d4dcce1f8d97a11b6972e13eb3f0b37654` (`green/deps.edn`) |
| colors-compute | `09ec539e75dc21c4dafb019eb8f9da276e695f6f`, the same SHA in `green/deps.edn`, `red/package.json` and `blue/pyproject.toml`; the pin that brought the AWS provider and the managed S3 backend |
| OpenTofu | 1.12.5 from `devenv` (`devenv.lock` is tracked in the deployment for this reason); the 1.11-only message match in the storage preflight broke at this version |
| ansible-core | 2.21.3 from `devenv` |
| AWS provider, storage stage | `hashicorp/aws` 6.31.0 |
| workstation | `redis-cli` 8.10.1, awscli 2.35.11, babashka 1.13.219, all from `devenv` |
| AMI | `ami-025d99823a4caad37`, booted as Ubuntu 24.04.4 LTS; login user `ubuntu`; `ufw` inactive as shipped |
| Instance | `t3.small` (2 vCPU, 2 GiB), root volume 20 GiB gp3, encrypted |
| Network | VPC `10.79.0.0/16`, subnet `10.79.1.0/24`, one internet gateway, security group `<profile>-firewall` with ingress 22/tcp from `0.0.0.0/0` alone, all owned by `colors-compute` |
| SSH | keygen mode: ed25519 key pair named after the profile, registered from the generated public key; `~/.ssh/config` block with `User ubuntu`, `IdentitiesOnly yes` |
| State bucket | `<profile>-state-<account>-<region>`, `s3-bucket-mode: managed`; four objects after a converge: `_colors/backend-owner.json`, `<profile>/compute/coordination.json`, `compute/shared.tfstate`, `compute/nodes/0.tfstate`, plus `<profile>/redis-storage.tfstate` |
| Backup bucket | `<profile>-backup-<account>-<region>`, `redis-storage-managed: true`; endpoint `https://s3.us-east-1.amazonaws.com`; rclone provider `AWS` with `no_check_bucket` and `no_head` kept |
| Backup schedule | `*-*-* 00/6:00:00`, retention 7 days, `redis-backup-max-age-hours: 8` |
| host packages | the same apt list the Vultr play installs (`docker.io`, `docker-compose-v2`, `ca-certificates`, `curl`, `jq`, `openssl`, `python3`, `rclone`); their versions were not recorded on this build, so the Vultr rows above are the last observation |

Backup sets from this build:
`redis-aws-backup-251213589273-us-east-1/redis-aws/redis/{20260911T034935Z,20260911T035615Z,20260911T040047Z,20260911T041005Z,20260911T041136Z}/`,
248-byte RDBs with `dbsize=1` from the first two converges and 288-byte
RDBs with two keys once the acceptance had written `colors:operator`;
recovery marker `redis-aws set=20260911T041136Z at=20260911T041148Z`, 50
bytes, AES256. The bucket and every set in it were destroyed by the
authorized delete.

Wall times at these pins: a passing create 193 to 197 s (compute 97 s,
storage 18 to 20 s, converge 65 s, acceptance 9 s); `describe` 18 s;
`rehearse` 38 s; the authorized delete 208 s (compute 145 s); the repeat
delete 5 s.

## The rules that generated it

### Digest-pin the image

Docker Hub republishes the `7.2` and `7.2.16` tags whenever the base image
is rebuilt, so a tag alone does not pin bytes. The companion package's
validator requires `tag@sha256:…` on `redis-image` for this reason. (Rule,
not measured on either build: no republish happened during them.)

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

### Three colours, one render

The package renders every fixture byte-identically through green, red and
blue, and `scripts/parity.sh` fails otherwise. Green owns the templates;
the red and blue resource trees are copies the script checks. A template
fix therefore lands in three places in one commit (the SSE fix touched
all three `main.tf` copies and one golden), and a behaviour fix lands in
three modules with three tests (the cleanup-play fix).

### Match OpenTofu's no-state message by its shared phrase

`tofu state list` on a stage with no state exits 1 and prints `No state
file was found!` on 1.11 and `Error: No state file was found` on 1.12.
The preflight runs it with `-no-color`, matches `No state file was found`
and treats only exit 1 with that phrase as an empty state. Every other
non-zero result stays an error, because a failed state read never means
absence.

### Declare what the AWS provider reads back

`aws_s3_bucket_server_side_encryption_configuration` under provider 6.31
must declare `blocked_encryption_types = ["SSE-C"]` and
`bucket_key_enabled = false`, the values AWS reports on a new bucket, or
the rule is rewritten in place on every apply. The `clickhouse` package
met the same drift first (`18ea94a`).

### Read root-only files as root, whoever the alias logs in as

The workstation reads the password with `cat … 2>/dev/null || sudo -n cat
…` and the installed helpers re-execute themselves under `sudo -n` when
`id -u` is not 0. File modes stay as they are; the login user is the
variable, not the permissions.

### The cleanup play carries no credentials

On the delete DAG the storage stage runs after the play, so the managed
pair has not been read when the play runs; the play only stops the service
and is run without the pair. The converge play still receives it.

### Retest conditions

- Any host image change: confirm whether unattended-upgrades still runs
  minutes after first boot and restarts sshd; the connection retries stay
  either way, but the catalogue entry's timing claim is Vultr-image
  specific and was not measured on the AMI. Confirm the login user (`root`
  on Vultr and DigitalOcean, `ubuntu` on the AMI) and whether `ufw` ships
  enabled; the exposure claim rests on the listener gate and the public
  probe either way.
- Any `redis-image` bump: re-run the negative probe (AOF on, no
  `appendonlydir/`, expect 0 keys) — if a future major loads `dump.rdb` in
  that state, the scratch doctrine is merely redundant, but the catalogue
  entry becomes wrong. Re-check that `redis-cli --rdb -` still streams
  diskless with an EOF marker and that `redis-check-rdb` still ships in
  the image.
- Any rclone newer than ~1.64: `no_check_bucket`/`no_head` and the
  no-`rcat` rule may be unnecessary; retest before dropping them (carried
  from neon-single-node). On native S3 the flags were never tested off;
  a retest there is a separate question.
- Any OpenTofu bump: run `tofu state list -no-color` against an empty
  stage and check the message still contains `No state file was found`;
  the `empty-state?` unit test carries both known forms and is the place
  to add a third.
- Any `hashicorp/aws` bump in the storage stage: run `tofu plan
  -detailed-exitcode` after a converge and require exit 0; a new
  read-back attribute shows up as a perpetual in-place update.
- Any `colors-compute` bump touching the AWS adapter, the managed backend
  or the finalizer: re-run an authorized delete and a repeat delete, and
  audit absence by resource id; the delete order (play, config block,
  compute, backup bucket, state bucket) is what the package relies on.
- A Docker that stops publishing on a specific host address: re-run the
  listener gate and the public-port probe before trusting the exposure
  claim.
- The red and blue launchers: their live AWS lifecycles passed at pin
  `ffb0777` on 2026-09-11 (create x2, describe, rehearse, delete x2 each,
  no fixes needed); a pin bump retests all three colours, not green alone.
