# AWS deployment: completed lifecycle and findings

## Evidence boundary, 2026-09-11 completed lifecycle

On 2026-09-11 the [`getcolors/n8n`](https://github.com/getcolors/n8n) Package
Skill gained AWS support in all three colours (feature commit
`2979693f3371b69cc26d93d413bfcea18b0089d5`, launchers pinned in `cf35a44`),
modelled on the langfuse package's AWS port, and the public
[`getcolors/n8n-aws`](https://github.com/getcolors/n8n-aws) deployment
(profile `n8n-aws`, host `n8n-aws.bigconfig.online`, AWS account
`251213589273`, `us-east-1a`, `t3.xlarge`, AMI `ami-025d99823a4caad37`, VPC
`10.76.0.0/16`) ran the full lifecycle against it the same day from the
workstation at `89.168.97.254`. The deployment's `verification.md` and
`evidence/*.txt` at commit `e41c76c` are the record; the file names below
are theirs, and every quoted string is copied from them.

The morning's blocker cleared first: a re-minted Cloudflare token answered
`status: active` on the account verify endpoint, expiring 2026-09-19 (see
[the Cloudflare section](#cloudflare-answers-9109-for-a-token-that-worked-the-day-before)).
Then, in order:

1. **Create 1** (`live-create-1.txt`): exit 0 after 677 s. Compute 133 s,
   storage 29 s, DNS 7 s, SSH config 1 s, Ansible 502 s, acceptance 4 s.
   Package `be6a5ef`, launcher stamped by `91a483d`.
2. **Host gates** (`smoke-after-create-1.txt`): all 18 passed in 27 s,
   `R2 backup credential is scoped away from live data` in `split` mode
   among them. **Public checks** (`public-after-create.txt`): the record is
   `{"type":"A","content":"54.234.176.151","proxied":true}`; the edge
   answered `200 server=cloudflare` on `/healthz/readiness` and 200 on
   `/rest/settings`; the certificate is `issuer=C = US, O = Let's Encrypt,
   CN = YE2`; origin 443 and 80 from the workstation gave `000 curl_exit=28`;
   origin 22 `open`.
3. **Storage audit** (`storage-after-create.txt`), **IAM isolation in both
   directions** (`credential-isolation.txt`), **local SSH ownership**
   (`local-ssh-after-create.txt`), **timers** (`units-after-create.txt`).
4. **Backup** (`backup-1.txt`): `backup set 20260911T065341Z uploaded`,
   `exit=0 elapsed=15s`, after `neon-n8n-runners-1` and `neon-n8n-1` stopped
   in that order. **Restore `--verify-only`** (`backup-verify-1.txt`):
   `backup set 20260911T065341Z verified against its manifest`.
5. **Soak** (`soak-1.txt`): `soak: 2930 executions, 0 failed, 10 workflows`,
   `sql round-trip p95=120ms p99=153ms`, `host memory 12% disk 28%`, S3
   objects under the deployment prefix `19 -> 22`, passed at the deployment's
   thresholds of 150 ms and 500 ms, `elapsed=304s`.
6. **Restore rehearsal** (`rehearsal-1.txt`): 130 tables restored, the
   pinned image booted ready, `{"login":true,"workflow":true,
   "credential":true,"binary":true,"credentialDetail":"a node using the
   credential executed successfully","executionCount":2}`, `elapsed=56s`.
   **Prune drill** (`prune-drill-1.txt`): 528 executions pruned to the cap
   of 5, `elapsed=151s`. **Restart drill, recreate** (`restart-drill-1.txt`):
   the stack returned healthy with no manual sequencing, the witness
   survived, a Code node still executed, `elapsed=51s`. **Monitor**
   (`monitor-1.txt`): `heartbeat`.
7. **Create 2** (`live-create-2.txt`): exit 0 after 304 s. Idempotent at the
   application layer; the storage plan afterwards was not empty
   (`storage-plan-after-create-2.txt`, the
   [SSE section](#the-storage-stage-plans-the-sse-update-on-every-converge)).
8. Package `e95536f`, launchers `9238423`, checkout
   `600b8092e38ebd996f37f1a1a2ad345580bc262a`. **Create 3**
   (`live-create-3.txt`): exit 0 after 287 s, and `tofu plan` then read
   `No changes. Your infrastructure matches the configuration.` with
   `plan exit=0` (`storage-plan-after-create-3.txt`).
9. **Delete guard** (`delete-guard.txt`): without the override, `compute
   destruction is protected; set COLORS_PAR_COMPUTE_PREVENT_DESTROY=false to
   delete`, `guard exit=2`. **Delete 1** (`live-delete-1.txt`): exit 0 after
   251 s in the order load, Ansible, SSH config, DNS, storage,
   infrastructure, backend finalize. **Delete 2** (`live-delete-2.txt`):
   exit 0 after 4 s through load and backend finalize only.
10. **Audit after delete** (`audit-after-delete.txt`): `n8n-aws buckets: 0`,
    `instances (non-terminated): 0`, `keypairs: 0`, `security groups
    non-default: 0`, `volumes: 0`, `iam users: colors`, `dns n8n-aws
    records: []`, `no ~/.ssh/n8n-aws key`, `ssh alias blocks: 0`. The three
    `eu-west-1` buckets in the listing predate the deployment and belong to
    the ONCE work.

The deployment no longer exists. Two findings came out of the day: the
acceptance step's sudo read, fixed before create 1 and passing in all
three creates; and the SSE drift, found after create 2 and fixed before
create 3. Only the green launcher ran: the deployment's `skills-lock.json`
records `package-n8n-green`. Red and blue are held byte-identical by parity
and have not converged on AWS.

Every claim below carries one of three labels:

- **verified live**: observed on the deployment above, with the evidence
  file named.
- **offline-validated**: exercised by a unit test, a golden render, parity,
  the syntax check or the dry run, and not by the live run, because the
  deployment's desired state did not take that path.
- **source-derived**: read from the package source or a sibling package's
  source; no host has done it.

The Vultr claims elsewhere in this skill keep their 2026-09-01 provenance
and are not affected by anything here.

This Context Skill carries no copies. The implementation is the package's:
`green/src/clj/io/github/getcolors/n8n/{storage,validate,workflow,tools,compute}.clj`,
`green/src/resources/io/github/getcolors/n8n/tools/storage/main.tf`, and
`tools/ansible/{n8n-env.sh,n8n.yml,n8n-smoke.sh}`, with the red and blue
ports held byte-identical by parity, and the fixture `test/fixtures/aws.yml`.
Read those for what the code does; read this for why, and for what is still
unproven.

## The neon-r2 keys select S3 by endpoint, not by name

Verified live for the endpoint path; the validator's grammar rules are
offline-validated.

The deployment's `colors.yml` carries `neon-r2-bucket`,
`neon-r2-endpoint: https://s3.us-east-1.amazonaws.com` and
`neon-r2-region: us-east-1`. The names say R2 because they are the vocabulary
of the `getcolors/neon` templates this package renders off the classpath
instead of copying (see the SKILL body); renaming them would mean forking the
storage tier. The endpoint is what makes them S3.

On the host, `n8n-env.sh` builds its two rclone remotes with
`PROVIDER=Cloudflare` and then flips each to `AWS` by a `case` on the endpoint
suffix (`https://*.amazonaws.com`, with and without a trailing slash, and the
`.com.cn` pair). That path carried the whole day: gate A2a saw 18 pageserver
objects and gate A2b a new safekeeper segment after `pg_switch_wal()`
(`smoke-after-create-1.txt`); the soak grew the deployment prefix from 19 to
22 objects (`soak-1.txt`); the backup set uploaded with `copyto`
(`backup-1.txt`) and listed back through the `backup:` remote as
`20260911T065341Z/manifest.txt`, `n8n-data.tar.gz` and `n8n.dump`
(`credential-isolation.txt`). The `no_check_bucket` and `no_head` settings
inherited from the R2 build did no harm against the regional endpoint.

The validator adds no AWS-specific key check beyond managed storage: with
`n8n-storage-managed: true` it requires `neon-r2-region` to match
`[a-z]{2}(?:-[a-z]+)+-\d+`, the backup region to equal it, and both bucket
names to satisfy S3's grammar. The unit suites exercise those rules; the live
deployment only ever presented valid values.

## The backup credential never reached the host before this port

The finding is source-derived, a code-review reading of the diff of `2979693`
against its parent. The fix is verified live.

Before the port the launcher validated `COLORS_PAR_N8N_BACKUP_R2_ACCESS_KEY_ID`
and `_SECRET_ACCESS_KEY` (`validate/backup-credential-scoped?`, the rule that
refuses a create without them unless `r2-credential-sharing: shared-accepted`
is recorded), and nothing rendered them into any template. `n8n-env.sh` built
one rclone remote, `r2:`, from `/etc/neon/r2.env`, the Neon pair the upstream
play installs, and every backup upload went through it. The smoke gate's R2
check tested `${COLORS_PAR_N8N_BACKUP_R2_ACCESS_KEY_ID:-}` on the host, where
the controller's environment does not exist, so it took the `RISK` branch on
every run. Had the variable somehow been present, the probe listed the Neon
bucket through the same `r2:` remote, with the Neon pair, so it would have
reported `FAIL` instead. There was no input under which that gate could pass.

This is the skill's own "blast radius is a gate, not a note" lesson, one step
further: the gate was written, installed and invoked, and still measured
nothing, because the thing it measured never left the controller. The
2026-09-01 Vultr build printed `RISK` and the operator read it as the accepted
shared-credential posture, which it was, and which the gate had not checked.

The fix, in the same commit:

- the play installs `/etc/colors/backup-r2.env` (mode `0600`, root-owned)
  from the two `COLORS_PAR_N8N_BACKUP_R2_*` lookups, through `copy: content:`,
  which is templated (the `password authentication failed` catalogue entry is
  why that spelling matters)
- `n8n-env.sh` builds two remotes, `store:` from `/etc/neon/r2.env` and
  `backup:` from `/etc/colors/backup-r2.env`, and sets `BACKUP_CREDENTIAL_MODE`
  to `split` when the backup pair is present, `shared` when it is empty and
  desired state records `shared-accepted` (the backup remote then reuses the
  Neon pair), and `none` otherwise
- the play refuses to converge on `none`: "no backup credential: supply
  COLORS_PAR_N8N_BACKUP_R2_* or record r2-credential-sharing: shared-accepted"
- gate R2 builds a `probe:` remote from the backup pair and the store endpoint
  and lists the Neon prefix with it, on the host; a listing that succeeds is
  `FAIL`, a refusal is `pass`, `shared` prints `RISK`, `none` is `FAIL`

What the endpoint answered (`credential-isolation.txt`, run as root on the
host, `BACKUP_CREDENTIAL_MODE=split`): the backup pair listed the backup
bucket, and each pair was refused the other bucket by IAM, not by rclone:

```
2026/09/11 06:54:20 ERROR : : error listing: AccessDenied: User: arn:aws:iam::251213589273:user/n8n-aws-storage-backup is not authorized to perform: s3:ListBucket on resource: "arn:aws:s3:::n8n-aws-neon-251213589273-us-east-1" because no identity-based policy allows the s3:ListBucket action
	status code: 403, request id: CWCH9A1KQBDFVEAS,
2026/09/11 06:54:20 ERROR : : error listing: AccessDenied: User: arn:aws:iam::251213589273:user/n8n-aws-storage-neon is not authorized to perform: s3:ListBucket on resource: "arn:aws:s3:::n8n-aws-backup-251213589273-us-east-1" because no identity-based policy allows the s3:ListBucket action
	status code: 403, request id: CWCVFVCM93DYG9WM,
```

That is the refusal the gate's `pass` line stands on. A pass from a
misconfigured probe remote (wrong endpoint, empty key) would print a different
error; the rclone line is what makes the gate evidence rather than a
tautology. Only the `split` branch ran on AWS: managed storage has no
operator pair to share, so `shared` and `none` stay offline-validated.

## Three S3 buckets, two owners

Verified live for creation, ordering, finalization and cleanup; the refusal
of a hand-made bucket is unverified.

| Bucket | Owner | Created | Removed |
|---|---|---|---|
| state (`s3-bucket`) | `colors-compute`, `s3-bucket-mode: managed` | before the first remote state read | last, after compute is gone, by `backend-finalize` |
| Neon data (`neon-r2-bucket`) | the package's `n8n-storage` stage, `n8n-storage-managed: true` | after compute, before DNS | after DNS, before compute |
| backup (`n8n-backup-r2-bucket`) | the same stage | same | same |

`storage-after-create.txt` shows the three buckets as created: the state
bucket tagged `colors:purpose=managed-backend`, `colors:owner=251213589273`
and `colors:profile=n8n-aws`, holding `_colors/backend-owner.json`,
`n8n-aws/compute`, `n8n-aws/n8n-dns.tfstate` and
`n8n-aws/n8n-storage.tfstate`; the Neon and backup buckets tagged
`colors:owner=n8n-storage` and `colors:profile=n8n-aws`, the Neon one holding
`n8n-aws/data`; all three with `{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}`
and `sse: AES256`. IAM: `n8n-aws-storage-backup policies=n8n-bucket
keys=Active` and `n8n-aws-storage-neon policies=n8n-bucket keys=Active`, the
backup policy's resources being exactly
`arn:aws:s3:::n8n-aws-backup-251213589273-us-east-1` and its `/*`. Compute:
one `t3.xlarge` in `us-east-1a` with `{"size":60,"type":"gp3","encrypted":true}`.

The create order in `workflow.clj` is infrastructure, storage, DNS, SSH
config, Ansible, acceptance, and that is the order `live-create-1.txt`
prints. The delete order is Ansible (stop the host), SSH config, DNS, storage,
infrastructure, backend finalize, and that is the order `live-delete-1.txt`
prints after its load step. A delete whose load step finds anything but
`present` under a managed state bucket sets `:n8n/finalize-only` and goes
straight to finalization: `live-delete-2.txt` shows exactly `:n8n/load`
(1070 ms) then `:n8n/backend-finalize` (2098 ms), exit 0. Finalization
accepts `destroyed`, `absent` and `skipped` from the library and refuses
anything else with "managed backend finalization refused"; the refusal
branch did not fire and stays source-derived.

The storage stage is one `main.tf` (provider `hashicorp/aws` 6.31.0): two
`aws_s3_bucket` resources by `for_each` over `{neon, backup}`, each with
`force_destroy = true` and `prevent_destroy` rendered from
`compute-prevent-destroy`, a public-access block with all four flags on, an
SSE rule (its shape is the next section), one `aws_iam_user` per bucket named
`<profile>-storage-<role>`, one inline policy per user allowing `ListBucket`,
`GetBucketLocation` and `ListBucketMultipartUploads` on the bucket and the
object verbs on `bucket/*`, and one `aws_iam_access_key` per user that
`depends_on` the policy. The `credentials` output is a sensitive object keyed
by role. The one-run destroy override `COLORS_PAR_COMPUTE_PREVENT_DESTROY=false`
overlays the flat key, so the render for that run carries
`prevent_destroy = false` on both buckets; on R2 desired state delete leaves
every bucket untouched, on managed S3 it removes the Neon data and every
backup set. Delete 1 removed both application buckets in the storage step
(14845 ms) while the host was already stopped, and the audit afterwards
found none.

`storage/ownership-preflight!` runs on create before apply: `tofu init`,
`tofu state list` (an absent state file is fine, any other failure is not),
then for each role whose Terraform address does not already record the
configured bucket name, `aws s3api head-bucket --bucket <name> --region
<neon-r2-region>`. Only a non-zero exit whose stderr matches
`\(404\)|Not Found|NoSuchBucket` passes; a `403`, a network failure and a
successful probe all fail closed with "managed storage refuses to adopt an
existing or inaccessible bucket". Create 1 ran that probe against two absent
buckets with no state file and its storage stage passed, which the preflight
allows only when the installed CLI's stderr matched the regex; creates 2 and
3 passed through the tracked Terraform address instead. What is unverified
is the refusal: no bucket was made by hand under a managed name, so the
`403` and the successful-probe branches, and the refusal text, have not been
seen.

The minted pairs are read from the sensitive output into memory and reach
Ansible as `COLORS_PAR_NEON_R2_*` and `COLORS_PAR_N8N_BACKUP_R2_*` in the
subprocess environment only (`storage/credential-env`, consumed by
`tools/managed-ansible-step`, which runs `ansible-playbook` directly because
`green.ansible/ansible-step` has no environment hook). `credential-env`
throws "managed storage credentials unavailable" when either pair is blank,
so a converge never starts with an empty credential. Nothing renders them:
`ansible-data` drops `:n8n/storage-credentials` before templating. Because
each pair is scoped to one bucket by construction, `secret-errors` skips the
operator pairs and the credential-sharing gate in managed mode; the
deployment's `.envrc.private` holds only the AWS pair, the Cloudflare token
and the encryption key. That the pairs reached the host is verified live by
`credential-isolation.txt` (`BACKUP_CREDENTIAL_MODE=split` as root) and by
gate R2.

## The storage stage plans the SSE update on every converge

Verified live: observed after create 2, fixed, and gone after create 3.

Create 2 returned exit 0, and the storage stage reported an apply rather
than a no-op. A read-only `tofu plan` in the rendered `n8n-storage` directory
afterwards (`storage-plan-after-create-2.txt`) showed
`Plan: 0 to add, 2 to change, 0 to destroy.`, `plan exit=2`, both
`aws_s3_bucket_server_side_encryption_configuration.application["backup"]`
and `["neon"]` `will be updated in-place`:

```
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
```

The template declared `sse_algorithm = "AES256"` and nothing else. An
`aws s3api get-bucket-encryption` readback during the session, recorded in
the deployment's `verification.md`, showed that S3 now creates buckets with
`BlockedEncryptionTypes: SSE-C` and `BucketKeyEnabled: false`; provider
6.31.0 reads both back, finds neither declared, and plans to remove and
re-add the rule on every converge. Nothing fails: the apply succeeds, the
converge reports exit 0, and the drift is visible only to someone who runs
the plan afterwards. This is the same default/readback mismatch the
`clickhouse-replicated` skill recorded at the same provider pin on
2026-09-10; that package's template already declares both attributes.

The fix, `e95536f`, declares `blocked_encryption_types = ["SSE-C"]` and
`bucket_key_enabled = false` beside the AES256 default, keeping the denial
S3 applied rather than trying to remove it. Launchers `9238423`, checkout
`600b809`; create 3 then returned exit 0 after 287 s and the plan read
`No changes. Your infrastructure matches the configuration.`, `plan exit=0`
(`storage-plan-after-create-3.txt`).

Source-derived, an expectation and not an observation: the `langfuse`,
`automq` and `neon-multi-node` storage templates carry the same undeclared
rule in their working trees on 2026-09-11 (`4ce273a`, `debb50b`, `413eec3`),
so the same perpetual plan is expected there at provider 6.31.0 and has not
been observed for them by this skill.

The package has no post-apply drift gate in this stage; the plan after the
second create is the operator's to run, and `acceptance.md` now says why it
belongs in the sequence.

## Backup endpoint and region default to the Neon values

Offline-validated for the defaulting; the explicit values are verified live.

`n8n-backup-r2-endpoint` and `n8n-backup-r2-region` are optional keys.
`validate/backup-endpoint` and `backup-region` return the Neon value when the
key is absent or blank, and `ansible-data` writes the resolved values into the
template data, so the R2 desired state written on 2026-09-01 needs no edit and
renders byte-identically; the unit suite and the two Vultr goldens cover
that. The AWS deployment sets both explicitly to the regional endpoint and
`us-east-1`, and the backup set reached
`n8n-aws-backup-251213589273-us-east-1` through them (`backup-1.txt`,
`credential-isolation.txt`). Managed storage requires the two regions to be
equal, because one provider block creates both buckets.

## The AWS adapter is IPv4 only, the login is ubuntu, and AWS auth is ambient

Verified live, except where a line says otherwise.

- `compute/ipv4-only` strips every range containing `:` from a symbolic
  source set when `provider-compute` is `aws`, so `n8n-http-sources:
  cloudflare` resolves to Cloudflare's fifteen IPv4 ranges and the checksum
  recorded beside the compute stage covers that set. The security group as
  created reads `{"p":80,"n":15,"v6":0}`, `{"p":22,"n":1,"v6":0}` and
  `{"p":443,"n":15,"v6":0}` (`storage-after-create.txt`), and the ACME
  challenge arrived through a Cloudflare address: the certificate is Let's
  Encrypt's while the origin's 80 and 443 time out from the workstation
  (`public-after-create.txt`). Explicit operator CIDRs are left alone and
  validate against the provider as written, so listing `::/0` in
  `n8n-ssh-sources` is a validation error, not a silent drop; that refusal is
  offline-validated by the unit suite. A real create refuses the fallback
  range list ("Cloudflare origin ranges unavailable") rather than widening;
  the branch did not fire and is source-derived.
- The AMI is declared as Ubuntu 24.04 amd64 and the SSH user is `ubuntu`, not
  `root`: the alias block the SSH config play wrote reads `User ubuntu`
  (`local-ssh-after-create.txt`), and `sudo` is required to read
  `/etc/n8n/secrets/` and `/etc/neon/secrets/`, which the deployment's README
  spells out and the next two sections bear on.
- The validator's `provider-secrets` lists only `cloudflare-api-token`; no
  `COLORS_PAR_AWS_*` is required. `storage/aws-env` forwards
  `COLORS_PAR_AWS_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` and `_SESSION_TOKEN`
  into the subprocess environment as `AWS_*` when they are set, for the
  compute library, the storage stage, the DNS stage's S3 backend and backend
  finalization; the deployment's `.envrc` maps the same pair onto `AWS_*` for
  everything else, including the `aws s3api head-bucket` probe. Every stage
  of every run authenticated that way. An operator with an empty pair gets
  whatever the ambient chain resolves to, and the first message is the
  provider's, not the package's; that case is source-derived.

## The acceptance step reads the role password through sudo

Verified live: a code-review finding fixed before create 1, then observed
passing in all three creates.

Until `be6a5efbf39a9c61341139172b2924f1e78d3a47`, `tools/read-remote-password`
ran `ssh <alias> cat /etc/neon/secrets/neon_role_password` with no `sudo`.
The upstream play creates `/etc/neon/secrets` with mode `0700` as root. As
`root` on Vultr that read works, and it did on 2026-09-01. As `ubuntu` on AWS
the same command is refused, and the acceptance step would have failed with
"acceptance: could not read the generated role password over ssh" after a
converge whose host-side gates all passed. The langfuse port this one was
modelled on reads the same class of file with `sudo -n cat --`; `be6a5ef`
gives all three colours the form `ssh -o BatchMode=yes <alias> sudo -n cat --
/etc/neon/secrets/neon_role_password`, and `91a483d` stamps it into the
launchers.

On the deployment the acceptance step completed in 4246 ms in create 1,
4037 ms in create 2 and 4042 ms in create 3, and `verification.md` records
that it "read the generated role password as `ubuntu` through `sudo -n` and
completed the tunnelled SQL round trip with it, and was refused without it".
If a future run fails at that message, inspect `sudo -n` for the `ubuntu`
login before suspecting the password file.

## Sourcing n8n-env.sh without sudo reports none

Verified live, a diagnostic trap recorded in `backup-verify-1.txt`.

`n8n-env.sh` reads the backup pair with `sed` from
`/etc/colors/backup-r2.env`, which the play installs root-owned, mode
`0600`, and it sends `sed`'s errors to `/dev/null`. Sourced as `ubuntu`, the
read yields two empty strings, the script sets `BACKUP_CREDENTIAL_MODE=none`,
and the `backup:` remote has no key. An operator who then lists the backup
bucket by hand sees

```
BACKUP_CREDENTIAL_MODE=none
2026/09/11 06:54:08 Failed to lsf: error in ListJSON: AccessDenied: Access Denied
	status code: 403, request id: JJTWFAT0KQ4RY1GJ, host id: mnJ3zF9YEDKkCvSQne0X63aooZYvw9IFqgteqXrBug4yH640kec6VHKTiGYQpvQSvKtAbTTHl31U2LaqjFOPuFpO9VO3Vp2T
```

on a host where, moments earlier, the backup service had uploaded a set and
`--verify-only` had matched it, and where the same probe as root prints
`BACKUP_CREDENTIAL_MODE=split` and the listing (`credential-isolation.txt`).
The `AccessDenied` here is S3 refusing an anonymous request, not a policy
refusing a key; it reads like the isolation gate failing in the wrong
direction. The systemd units run as root and never see this. Read the mode
line before the rclone line: `none` on a host whose play converged means the
reader, not the host, lacks the credential.

## Cloudflare answers 9109 for a token that worked the day before

Observed on the build machine on 2026-09-11. This is not an AWS claim; it is
why the lifecycle ran in the afternoon rather than the morning.

`GET /zones?name=<zone>` answered HTTP 403
`{"code":9109,"message":"Invalid access token"}` for every token on the
machine, including the one that had created a record in the same zone the day
before from the same egress address. Repeated probes escalated to
`{"code":10502,"message":"Too many authentication failures. Please try again
later."}` for several minutes, for every token. Probe once per token, not in
a loop; the second message hides the first.

The cause came from the one endpoint that reports an account-owned token's
state: `GET /accounts/<account id>/tokens/verify`, with the account id taken
from the R2 endpoint host, answered `{"status":"expired"}` for the shared
token and `Invalid API Token` for the four older ones. The shared token had
a TTL; the others were revoked. `/user/tokens/verify` cannot answer for an
account-owned token at all (the catalogue's zone-scoped entry), and `/zones`
only says no. A new token is the next step either way, but ask the account
endpoint first: it names the cause and it does not feed the lockout.

The user re-minted the token; the same account endpoint answered
`status: active` with an expiry of 2026-09-19, and the DNS stage ran in 7 s
on create 1. A token with a TTL is a retest condition of its own: the next
converge after 2026-09-19 will meet 9109 again unless the token is renewed
first.

## What remains unverified

Each of these is outside what the 2026-09-11 evidence covers.

1. **Host package versions on the AMI.** The evidence does not capture
   `docker.io`, `docker-compose-v2`, `postgresql-client`, `rclone` or the
   kernel as installed on `ami-025d99823a4caad37`; the pins table's host
   row stays the 2026-09-01 Vultr observation. `pg_dump` ran inside the
   compute container, so the client-16 trap was not exercised either way.
2. **Behaviour beyond a five-minute soak.** One host, ten concurrent
   workflows, 300 s, no competing tenant. Days of operation, pruning of a
   large execution table under load, a pageserver restart under load, and
   `t3` CPU-credit exhaustion are all unmeasured.
3. **A create against a hand-made bucket** under one of the managed names.
   Not attempted; the ownership preflight's refusal branches and the text
   the installed AWS CLI prints for a `403` have not been seen.
4. **Red and blue on AWS.** Parity holds byte for byte and the suites pass;
   no red or blue launcher converged there.
5. **The unattended reboot drill.** The restart drill that ran was the
   recreate lifecycle (`restart-drill-1.txt`); the reboot variant the
   acceptance doctrine describes was not run on AWS.
6. **Scheduled timer firings.** `units-after-create.txt` shows both timers
   `active waiting`; the deployment lived under three hours, so the six-hour
   backup timer never fired on its own. The backup and monitor runs in the
   evidence were started during the session.
7. **Whole-host recovery into a fresh create.** The rehearsal restored into
   a scratch stack on the same host. Restoring a set from the backup bucket
   into a newly created host was not done.
8. **The `shared` and `none` branches of gate R2** on AWS: managed storage
   only ever produces `split`.
9. **A delete while a backup is running.** Delete 1's Ansible step stopped
   the host before storage removal; whether a set mid-upload races the
   bucket's `force_destroy` was not provoked.
10. **The other packages' SSE drift.** Expected from source for `langfuse`,
    `automq` and `neon-multi-node`, observed only here and in
    `clickhouse-replicated`.
