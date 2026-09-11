# Failure catalogue

Symptom-indexed, verbatim where the text was verbatim. Entries marked
*(this build)* were hit or deliberately reproduced on `redis-vultr` on
2026-09-03; entries marked *(redis-aws)* were hit on the AWS build on
2026-09-11, each at the pins in `pins.md`; entries marked with another
build name were paid for there and are carried here because a single-node
Redis deployment meets them too.

## A restored `dump.rdb` loads zero keys *(this build, reproduced)*

```
DBSIZE
(integer) 0
```
with, in the container log:
```
* Creating AOF base file appendonly.aof.1.base.rdb on server start
* Creating AOF incr file appendonly.aof.1.incr.aof on server start
* Ready to accept connections tcp
```

The instance was started with `appendonly yes` and there was no
`appendonlydir/` beside `dump.rdb`. Redis 7 with AOF enabled loads **only**
the AOF manifest; finding none, it creates an empty base and an empty
increment file and never reads the RDB. The directory afterwards holds a
fresh `appendonlydir/` next to the untouched `dump.rdb`, and the server
answers `PONG` as if all were well. Reproduced deliberately with the
just-restored 288-byte set: `--appendonly no` → 2 keys; `--appendonly yes`
→ 0 keys.

Fix for a restore *check*: run the scratch with `--appendonly no --save ""
--dir /data --dbfilename dump.rdb`. For a real recovery onto a live host:
stop Redis, place `dump.rdb`, remove `appendonlydir/`, start with AOF on so
Redis rewrites the AOF base from the loaded RDB — a procedure that follows
from the rule above but was **not** executed on either build.

## `NOAUTH Authentication required.` with exit 0 *(this build)*

```
$ docker compose exec -T redis redis-cli --no-auth-warning PING
NOAUTH Authentication required.
$ echo $?
0
```
```
$ docker compose exec -T -e REDISCLI_AUTH=not-the-password redis redis-cli --no-auth-warning PING
AUTH failed: WRONGPASS invalid username-password pair or user is disabled.
NOAUTH Authentication required.
$ echo $?
0
```

Error replies are text on stdout and redis-cli exits 0 in non-interactive
mode. A converge gate that keys on the exit code reads both refusals as
success and an accepted anonymous `PING` as success too. Every gate must
capture the reply and grep it (`PONG`, `NOAUTH`, `WRONGPASS`), and a
negative gate must additionally fail on a `PONG` in the reply.

## A health check reading the reply with `head -c` prints nothing *(langfuse-multi-node)*

```
FAIL  A3 unauthenticated Redis PING answered 'nothing'
```

`head -c 64` on the 33-byte `NOAUTH Authentication required.\r\n` reply
blocks waiting for the remaining bytes until the timeout kills it, and the
buffered bytes are lost with it. Read a line (`head -1`, `read -t`) or
capture the whole reply; never a byte count larger than the reply.

## `ufw status` admits only 22 but the published port answers *(langfuse-multi-node; bindings verified on both builds)*

Docker's published ports bypass ufw through the DOCKER chain, so ufw's
rule list is not the exposure boundary for a container port. What bounds
exposure is the **bind list in the Compose `ports:`** and the provider
firewall. On the Vultr build: `ss -ltnH "sport = :6379"` listed exactly
```
LISTEN 0      4096   10.60.0.3:6379 0.0.0.0:*
LISTEN 0      4096   127.0.0.1:6379 0.0.0.0:*
```
and a bounded connect from the internet to `<public-ip>:6379`
(`timeout 5 bash -c 'exec 3<>/dev/tcp/<ip>/6379'`) failed while the tunnel
round-trip succeeded. The package has since dropped the VPC binding; on
the AWS build, where `ufw` is `Status: inactive` as the AMI ships it, the
kernel listed exactly
```
LISTEN 0      4096   127.0.0.1:6379 0.0.0.0:*
```
and the probe to `54.227.190.72:6379` exited 124 while port 22 opened.
Publish on `127.0.0.1:` (and a private address only if a peer needs it),
and gate on the kernel's listener list — never on `ufw status`.

## `UNREACHABLE` on a host booted minutes ago *(this build)*

```
[ERROR]: Task failed: Failed to connect to the host via ssh: kex_exchange_identification: read: Connection reset by peer
Connection reset by 78.141.212.44 port 22
fatal: [redis-vultr]: UNREACHABLE! => {"changed": false, "msg": "…", "unreachable": true}
PLAY RECAP: redis-vultr : ok=0 changed=0 unreachable=1 failed=0
```
and on the host:
```
sshd[10188]: Received signal 15; terminating.
sshd[10685]: Server listening on 0.0.0.0 port 22.
```
with `/var/log/apt/history.log` showing `Commandline: /usr/bin/unattended-upgrade`
entries for libpam-* and libssl3t64 at that minute, and
`unattended-upgrades.log` ending `All upgrades installed` two minutes later.

Ubuntu 24.04's `apt-daily-upgrade.timer` ran six minutes after the host's
first boot and the libpam/libssl upgrades restarted sshd; the play's one
connection attempt landed in that second. The host was reachable a minute
later with nothing wrong. Fix: `[ssh_connection] retries = 3` in
`ansible.cfg` and `wait_for_connection` ahead of every play, not only the
converge. (A `/etc/ssh/ssh_config line 53: Unsupported option
"gssapiauthentication"` line printed alongside is workstation noise from a
nix-built ssh reading the distro config; it appears on every successful
connection too.) The AWS build ran with both from the start and never met
the window.

## `docker inspect` RestartCount never goes down *(langfuse-multi-node)*

`RestartCount` is cumulative for the life of a container. A monitor
threshold on the raw count flags a container that once crash-looped and
has been healthy for hours — and keeps flagging it exactly because the
container was never recreated, which is the idempotence working. Pair the
count with `.State.StartedAt`: restarting *now* means a recent start.

## rclone → R2: `AccessDenied` on allowed writes, `501` from `rcat` *(neon-single-node)*

```
ERROR : … Failed to copy: AccessDenied: Access Denied
	status code: 403
```
```
NotImplemented: Not Implemented
	status code: 501
```

Ubuntu 24.04's rclone 1.60.1 precedes the first upload with a bucket
check/create that a bucket-scoped R2 token denies, and streams
unknown-size uploads (`rcat`) in a way R2 rejects. Set
`RCLONE_CONFIG_<REMOTE>_NO_CHECK_BUCKET=true`,
`RCLONE_CONFIG_<REMOTE>_NO_HEAD=true`, and always `copyto` a known-size
file. Both builds ran with all three from the start and did not re-test
without them; on AWS the remote's provider is `AWS` instead of
`Cloudflare` (chosen by the `amazonaws.com` endpoint) and the two skips
stay on.

## Ansible: `failed at splitting arguments` on a fine-looking shell task *(langfuse-multi-node, neon-single-node)*

```
Error loading tasks: failed at splitting arguments, either an unbalanced jinja2 block or quotes
```

A `shell:` block whose comment carries an odd number of apostrophes.
Ansible counts quotes across the whole block, comments included, before
the shell ever sees it. Keep quoting-heavy shell in installed scripts and
run `ansible-playbook --syntax-check` on the rendered tree offline; the
companion package's `bb syntax` does both in a second.

## A keygen deployment refuses its own provider SSH key *(langfuse-multi-node; preflight re-proven on this build)*

```
vultr already has an SSH key named <profile> (id …) that is not in this
deployment's state and matches ~/.ssh/<profile>.pub: a previous delete left
it behind. Verify no host for <profile> survives, delete that key at the
provider, and retry.
```

Not a leftover key: the deployment's own state held it, but the package's
`state-fn` had normalized the tofu output to kebab-case and ONCE's create
matrix reads `:ssh_key_id` **with the underscore**. Return the keywordized
params untouched; add derived keys beside the originals. The redis
package's second Vultr converge passed this preflight with the key in
state. The package has since moved its compute and keypair lifecycle to
`colors-compute`, which has no `state-fn` to normalize.

## The first create fails at the storage stage after the instance exists *(redis-aws)*

The launcher's whole output for the step:
```
>>> :redis/storage (create)
<<< :redis/storage (6690ms)
managed S3 storage failed; inspect bucket ownership, state access, and AWS permissions
EXIT=1 ELAPSED=138s
```
Reproduced by hand in `.colors/<profile>/redis-storage`, where `tofu state
list` on OpenTofu 1.12.5 printed
```

Error: No state file was found

State management commands require a state file. Run this command in a
```
where OpenTofu 1.11.5 prints
```
No state file was found!
State management commands require a state file. Run this command
```

The managed-bucket ownership preflight treated the stage as empty only
when stderr carried the 1.11 string, exclamation mark included. Under
1.12.5 the message gained an `Error:` prefix and lost the bang (and is
coloured unless `-no-color`), so the check threw `managed storage state
unavailable`, which the launcher reported as the one line above. The
instance had already been created by the compute stage; every later create
adopted it cleanly through the library's ownership coordination. The
neon-multi-node AWS build never met this because its `devenv.lock` had
pinned OpenTofu 1.11.5.

Fix (`getcolors/redis@7e51e2d`): run `tofu state list -no-color` and treat
exit 1 with `No state file was found` anywhere on stderr as the empty
state, through a tested `empty-state?` predicate that also rejects exit 0
with empty output, `Error: error loading the remote state: AccessDenied`,
and exit 2 with the old string. Anything else still fails closed: a failed
state read never means absence. Note the launcher log carries no tool
output at all for this failure; reproduce in the stage directory rather
than guessing from the message.

## `acceptance: could not read the generated Redis password over ssh` *(redis-aws)*

```
>>> :redis/acceptance (create)
<<< :redis/acceptance (6518ms)
acceptance: could not read the generated Redis password over ssh
EXIT=1 ELAPSED=243s
```
because `ssh <alias> cat /etc/redis/secrets/password` answered
`Permission denied`. The same login broke the installed helper:
`ssh <alias> redis-status` could not read `/etc/colors/backup-r2.env`
or the Docker socket.

The AWS Ubuntu AMI logs in as `ubuntu`; the Vultr and DigitalOcean images
log in as root, and both workstation-side reads had assumed root. The
storage stage and the whole converge had already passed, so the failure
looked like a broken deployment when it was a broken read.

Fix (`getcolors/redis@f51654e`): the acceptance reads with one remote
command, `cat /etc/redis/secrets/password 2>/dev/null || sudo -n cat
/etc/redis/secrets/password`, which serves a root login through the first
half and an `ubuntu` login through passwordless sudo; `redis-status`
starts with `[ "$(id -u)" -eq 0 ] || exec sudo -n "$0" "$@"`; and the
documented one-liner is `REDISCLI_AUTH=$(ssh <profile> sudo -n cat
/etc/redis/secrets/password) redis-cli -p 6379`, which works as root too.
File modes are unchanged: the password stays 0600 root-only, the login
user is what varied. `describe` never needed the fix because the monitor
result it reads is 0644. A failed read returns nothing rather than a
partial reply, so the gate fails instead of trying an empty password.

## The storage stage plans one change after every converge *(redis-aws)*

```
# tofu plan -detailed-exitcode after create 2
## .colors/redis-aws/redis-storage
Plan: 0 to add, 1 to change, 0 to destroy.
plan exit=2 (0 = no changes, 2 = changes)
```
with the plan body
```
  # aws_s3_bucket_server_side_encryption_configuration.application["backup"] will be updated in-place
  ~ resource "aws_s3_bucket_server_side_encryption_configuration" "application" {
        id     = "redis-aws-backup-251213589273-us-east-1"
        # (2 unchanged attributes hidden)

      - rule {
          - blocked_encryption_types = [
              - "SSE-C",
            ] -> null
          - bucket_key_enabled       = false -> null

          - apply_server_side_encryption_by_default {
              - sse_algorithm = "AES256" -> null
            }
        }
      + rule {
          + blocked_encryption_types = []

          + apply_server_side_encryption_by_default {
              + sse_algorithm = "AES256"
            }
        }
    }
```

AWS reports `blocked_encryption_types = ["SSE-C"]` and
`bucket_key_enabled = false` on a new bucket's encryption rule, and the
template declared neither, so `hashicorp/aws` 6.31.0 rewrote the rule in
place on every apply. The converge itself exits 0 each time; only the
idempotence proof (`plan -detailed-exitcode` = 0) fails, forever. The
`clickhouse` package met the same drift first (`18ea94a`).

Fix (`getcolors/redis@dccd696`): declare both attributes in the rule.
After the next converge:
```
No changes. Your infrastructure matches the configuration.
plan exit=0 (0 = no changes)
```

## An authorized delete stops at the cleanup play with `managed storage credentials unavailable` *(redis-aws)*

```
>>> :redis/load-infrastructure (delete)
<<< :redis/load-infrastructure (15804ms)
>>> :redis/ansible (delete)
managed storage credentials unavailable
clojure.lang.ExceptionInfo: managed storage credentials unavailable {}
	at sci.lang.Var.invoke(lang.cljc:219)
	…
EXIT=1 ELAPSED=17s
```
Nothing was destroyed: the instance, both buckets, the key pair and the
IAM user were all still present afterwards.

The cleanup play was run with the credentials flag, so `run-play` asked
the storage namespace for the managed pair. On the create DAG that pair
comes from the storage stage, which runs before the play; on the delete
DAG the storage stage runs *after* the play, because the bucket outlives
the machine, so nothing had read it. The play itself only runs `docker
compose down` and reads no backup variable.

Fix (`getcolors/redis@ffb0777`): run the cleanup play without the pair, in
all three colours (`red/src/tools.ts` and `blue/…/tools.py` carried the
same flag), each with a test that a managed delete runs `cleanup.yml` with
host-key checking off alone while a managed create still hands the pair to
`main.yml`. The retried delete then ran ansible, ssh-config,
infrastructure, storage and backend-finalize in 208 s.

## A plan from `.colors/` wants to replace the key pair and the instance *(redis-aws)*

```
## .colors/redis-aws/redis-infrastructure/shared
  # aws_key_pair.machine must be replaced
Plan: 1 to add, 0 to change, 1 to destroy.
## .colors/redis-aws/redis-infrastructure/nodes/0
  # aws_instance.node must be replaced
Plan: 1 to add, 0 to change, 1 to destroy.
Error: Resource instance cannot be destroyed
```

Not drift. `colors-compute` runs tofu in a private working directory it
removes, and the compute tree under `.colors/` is the build-time render
with the placeholder public key, so a plan there compares the real key
pair against a placeholder and proposes replacing it, and the instance
with it (`prevent_destroy` then refuses). Do not treat that plan as an
idempotence result, and remove the `.terraform/` it leaves behind. The
compute proof is the unchanged instance id, key pair id, volume id and
launch time across runs; the storage stage, which the package runs in
`.colors/<profile>/redis-storage` itself, is the one stage a plan from
`.colors/` can prove.

## `compute destruction is protected` *(redis-aws; the guard, not a failure)*

```
>>> :redis/start (delete)
<<< :redis/start (1ms)
compute destruction is protected; set COLORS_PAR_COMPUTE_PREVENT_DESTROY=false to delete
EXIT=2
```

A plain `delete` exits 2 at the start step before any provider or state
work; the instance was still running afterwards. On a deployment that
owns its backup bucket this is the only thing between an operator and the
loss of every backup set, since `force_destroy` empties the bucket. Lift
it for one run with the environment variable; never edit the committed
flag.
