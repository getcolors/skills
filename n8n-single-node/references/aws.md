# AWS deployment: offline validation and source-derived findings

## Evidence boundary, 2026-09-11 offline validation

On 2026-09-11 the [`getcolors/n8n`](https://github.com/getcolors/n8n) Package
Skill gained AWS support in all three colours: feature commit
`2979693f3371b69cc26d93d413bfcea18b0089d5`, launchers pinned in `cf35a44`,
then the sudo fix `be6a5ef` pinned in `91a483d`, modelled on the langfuse
package's AWS port. A public deployment repository,
[`getcolors/n8n-aws`](https://github.com/getcolors/n8n-aws) (profile
`n8n-aws`, host `n8n-aws.bigconfig.online`, `us-east-1a`, `t3.xlarge`, AMI
`ami-025d99823a4caad37`, VPC `10.76.0.0/16`), was created and pushed with the
published pin installed by the Skills CLI.

**No live converge has run and no AWS resource has been created.** What ran,
all of it offline:

- the unit suites in three colours: green 46 tests, red 58, blue 68
- golden renders for the three fixtures (Vultr keygen, Vultr opt-out, AWS
  with managed storage)
- three-colour parity, byte for byte, over all three fixtures
- `ansible-playbook --syntax-check` on the rendered tree
- `./green build` and `./green create --dry-run` from the deployment checkout

The converge is blocked because every Cloudflare API token on the build
machine answered `{"code":9109,"message":"Invalid access token"}` on
2026-09-11, including the token that created
`neon-multi-node-aws.bigconfig.online` the day before from the same egress
address. The DNS stage sits between storage and the converge, so nothing past
compute can run without it, and creating compute alone would leave a billable
instance with no name and nothing proven. See
[the Cloudflare finding](#cloudflare-answers-9109-for-a-token-that-worked-the-day-before)
and the failure catalogue.

Every claim below carries one of two labels:

- **source-derived**: read from the package source at `2979693` and from the
  deployment's `colors.yml`. It says what the code does; no host has done it.
- **offline-validated**: exercised by a unit test, a golden render, parity,
  the syntax check or the dry run. Still no host, no bucket, no instance.

Nothing in this file is verified live. The Vultr claims elsewhere in this
skill keep their 2026-09-01 provenance and are not affected by anything here.

This Context Skill carries no copies. The implementation is the package's:
`green/src/clj/io/github/getcolors/n8n/{storage,validate,workflow,tools,compute}.clj`,
`green/src/resources/io/github/getcolors/n8n/tools/storage/main.tf`, and
`tools/ansible/{n8n-env.sh,n8n.yml,n8n-smoke.sh}`, with the red and blue
ports held byte-identical by parity, and the fixture `test/fixtures/aws.yml`.
Read those for what the code does; read this for why, and for what is still
unproven.

## The neon-r2 keys select S3 by endpoint, not by name

Source-derived.

The deployment's `colors.yml` carries `neon-r2-bucket`,
`neon-r2-endpoint: https://s3.us-east-1.amazonaws.com` and
`neon-r2-region: us-east-1`. The names say R2 because they are the vocabulary
of the `getcolors/neon` templates this package renders off the classpath
instead of copying (see the SKILL body); renaming them would mean forking the
storage tier. The endpoint is what makes them S3.

On the host, `n8n-env.sh` builds its two rclone remotes with
`PROVIDER=Cloudflare` and then flips each to `AWS` by a `case` on the endpoint
suffix (`https://*.amazonaws.com`, with and without a trailing slash, and the
`.com.cn` pair). The validator adds no AWS-specific key check beyond managed
storage: with `n8n-storage-managed: true` it requires `neon-r2-region` to
match `[a-z]{2}(?:-[a-z]+)+-\d+`, the backup region to equal it, and both
bucket names to satisfy S3's grammar. The unit suites exercise those rules.
Whether rclone's `AWS` provider path against a real regional endpoint behaves
as the `Cloudflare` path did on 2026-09-01 (the `no_check_bucket` and
`no_head` settings, `copyto` over `rcat`) is unverified.

## The backup credential never reached the host before this port

Source-derived, a code-review finding. Read from the diff of `2979693`
against its parent; no host produced it.

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

- the play installs `/etc/colors/backup-r2.env` (mode `0600`) from the two
  `COLORS_PAR_N8N_BACKUP_R2_*` lookups, through `copy: content:`, which is
  templated (the `password authentication failed` catalogue entry is why that
  spelling matters)
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

The unit suites and goldens cover the rendering; the syntax check covers the
play. Whether a real S3 endpoint refuses an IAM key scoped to one bucket a
listing of the other is what the live run must prove.

## Three S3 buckets, two owners

Source-derived; the stage order is offline-validated by the workflow tests
and the dry run.

| Bucket | Owner | Created | Removed |
|---|---|---|---|
| state (`s3-bucket`) | `colors-compute`, `s3-bucket-mode: managed` | before the first remote state read | last, after compute is gone, by `backend-finalize` |
| Neon data (`neon-r2-bucket`) | the package's `n8n-storage` stage, `n8n-storage-managed: true` | after compute, before DNS | after DNS, before compute |
| backup (`n8n-backup-r2-bucket`) | the same stage | same | same |

The create order in `workflow.clj` is infrastructure, storage, DNS, SSH
config, Ansible, acceptance; the delete order is Ansible (stop the host), SSH
config, DNS, storage, infrastructure, backend finalize. A delete whose load
step finds anything but `present` under a managed state bucket sets
`:n8n/finalize-only` and goes straight to finalization: the bucket may already
be half-finalized or gone, and neither is a compute state to adopt.
Finalization accepts `destroyed`, `absent` and `skipped` from the library and
refuses anything else with "managed backend finalization refused".

The storage stage is one `main.tf` (provider `hashicorp/aws` 6.31.0): two
`aws_s3_bucket` resources by `for_each` over `{neon, backup}`, each with
`force_destroy = true` and `prevent_destroy` rendered from
`compute-prevent-destroy`, a public-access block with all four flags on, an
SSE rule with `sse_algorithm = "AES256"`, one `aws_iam_user` per bucket named
`<profile>-storage-<role>`, one inline policy per user allowing `ListBucket`,
`GetBucketLocation` and `ListBucketMultipartUploads` on the bucket and the
object verbs on `bucket/*`, and one `aws_iam_access_key` per user that
`depends_on` the policy. The `credentials` output is a sensitive object keyed
by role. The one-run destroy override `COLORS_PAR_COMPUTE_PREVENT_DESTROY=false`
overlays the flat key, so the render for that run carries
`prevent_destroy = false` on both buckets; on R2 desired state delete leaves
every bucket untouched, on managed S3 it removes the Neon data and every
backup set.

`storage/ownership-preflight!` runs on create before apply: `tofu init`,
`tofu state list` (an absent state file is fine, any other failure is not),
then for each role whose Terraform address does not already record the
configured bucket name, `aws s3api head-bucket --bucket <name> --region
<neon-r2-region>`. Only a non-zero exit whose stderr matches
`\(404\)|Not Found|NoSuchBucket` passes; a `403`, a network failure and a
successful probe all fail closed with "managed storage refuses to adopt an
existing or inaccessible bucket". The unit tests drive that regex with
synthetic strings (`(404) Not Found`, `(403) Forbidden`); what the installed
AWS CLI prints for a missing bucket is unverified here.

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
and the encryption key.

One shape worth knowing before the first live run: the clickhouse sibling
observed, at this same provider pin, that an SSE rule leaving
`blocked_encryption_types` and `bucket_key_enabled` unspecified read back as
`["SSE-C"]` and `false` and produced a perpetual plan diff (see
`clickhouse-replicated/references/aws.md`). The n8n stage carries the langfuse
shape, which leaves both unspecified. A live run must show a no-change plan in
`n8n-storage` after the first apply; I found no post-apply drift gate for this
stage in the package source, so that plan is the operator's to run.

## Backup endpoint and region default to the Neon values

Offline-validated: the unit suite and the two Vultr goldens render unchanged.

`n8n-backup-r2-endpoint` and `n8n-backup-r2-region` are new optional keys.
`validate/backup-endpoint` and `backup-region` return the Neon value when the
key is absent or blank, and `ansible-data` writes the resolved values into the
template data, so the R2 desired state written on 2026-09-01 needs no edit and
renders byte-identically. The AWS deployment sets both explicitly to the
regional endpoint and `us-east-1`; managed storage requires the two regions to
be equal, because one provider block creates both buckets.

## The AWS adapter is IPv4 only, the login is ubuntu, and AWS auth is ambient

Source-derived.

- `compute/ipv4-only` strips every range containing `:` from a symbolic
  source set when `provider-compute` is `aws`, so `n8n-http-sources:
  cloudflare` resolves to Cloudflare's fifteen IPv4 ranges and the checksum
  recorded beside the compute stage covers that set. Explicit operator CIDRs
  are left alone and validate against the provider as written, so listing
  `::/0` in `n8n-ssh-sources` is a validation error, not a silent drop. The
  deployment lists one `/32`. A real create refuses the fallback range list
  ("Cloudflare origin ranges unavailable") rather than widening.
- The AMI is declared as Ubuntu 24.04 amd64 and the SSH user is `ubuntu`, not
  `root`; `sudo` is required to read `/etc/n8n/secrets/` and
  `/etc/neon/secrets/`, which the deployment's README spells out.
- The validator's `provider-secrets` lists only `cloudflare-api-token`; no
  `COLORS_PAR_AWS_*` is required. `storage/aws-env` forwards
  `COLORS_PAR_AWS_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` and `_SESSION_TOKEN`
  into the subprocess environment as `AWS_*` when they are set, for the
  compute library, the storage stage, the DNS stage's S3 backend and backend
  finalization; the deployment's `.envrc` maps the same pair onto `AWS_*` for
  everything else, including the `aws s3api head-bucket` probe. An operator
  with an empty pair gets whatever the ambient chain resolves to, and the
  first message is the provider's, not the package's.

## The operator-side acceptance step read the role password without sudo

Source-derived, a code-review finding, fixed the same day; the fix is
unverified live.

Until `be6a5efbf39a9c61341139172b2924f1e78d3a47`, `tools/read-remote-password`
ran `ssh <alias> cat /etc/neon/secrets/neon_role_password` with no `sudo`.
The upstream play creates `/etc/neon/secrets` with mode `0700` as root. As
`root` on Vultr that read works, and it did on 2026-09-01. As `ubuntu` on AWS
the same command is refused, and the acceptance step would fail with
"acceptance: could not read the generated role password over ssh" after a
converge whose host-side gates all passed. The langfuse port this one was
modelled on reads the same class of file with `sudo -n cat --`; `be6a5ef`
gives all three colours that form, and `91a483d` stamps it into the
launchers. The AWS fixture, golden, parity and the three unit suites pass
with it; no host has run it. If a live run still fails at that message,
inspect `sudo -n` for the `ubuntu` login before suspecting the password
file.

## Cloudflare answers 9109 for a token that worked the day before

Observed on the build machine on 2026-09-11. This is not an AWS claim; it is
the reason there is no AWS evidence.

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

## What a live run must still prove

Each of these is settled only by a converge, and none of them is settled yet.

1. **Bucket creation and refusal.** Three buckets appear with the expected
   names, tags, public-access block and SSE; a second create against the same
   names passes the ownership preflight through the tracked Terraform
   address; a bucket created by hand under one of the names is refused, and
   the refusal text matches what the installed AWS CLI prints for a `404`.
2. **Scoped-key isolation, probed on the host.** Gate R2 in `split` mode
   passes because S3 refuses the backup pair a listing of the Neon prefix,
   and the Neon pair is refused the backup bucket the same way. A pass that
   comes from a misconfigured probe remote (wrong endpoint, empty key) would
   look identical; read the rclone error, not only the gate line.
3. **The Neon tier on native S3.** Pageserver objects appear under
   `<profile>/data/` and a new safekeeper segment appears after
   `pg_switch_wal()` (gate A2b) against `s3.us-east-1.amazonaws.com` with the
   `AWS` rclone provider, and the backup set uploads with `copyto`.
4. **The acceptance step as `ubuntu`.** See the section above.
5. **A no-change plan in `n8n-storage`** after the first apply, at provider
   6.31.0.
6. **Finalize ordering.** An authorized delete stops the host, removes the
   alias and the record, empties and removes the two application buckets and
   their IAM users while nothing is still writing, destroys compute, and
   removes the state bucket last with status `destroyed`.
7. **A second delete is idempotent.** The load step reports something other
   than `present`, the workflow takes the finalize-only path, and
   finalization reports `absent` with exit 0.
8. **The soak numbers on `t3.xlarge`.** The 2026-09-01 figures (7950
   executions, p95 75 ms, p99 80 ms) are `vhp-8c-16gb-amd` NVMe figures. A
   `t3.xlarge` on a gp3 root volume with burstable CPU credits is a different
   machine; the deployment inherits the same thresholds and the first live
   soak decides whether they hold.
9. **ACME behind the security group.** The record is proxied and the HTTP
   source set is Cloudflare's IPv4 ranges, so the HTTP-01 challenge should
   arrive from a Cloudflare address; gate B2 must show a valid certificate for
   the public name from loopback, and the outside check must show the origin
   refusing non-Cloudflare traffic.
10. **Cleanup on the operator side.** The `~/.ssh/config` block and the
    profile-named keypair are gone after delete, as the SSH Config and SSH
    Keypair Standards require.
