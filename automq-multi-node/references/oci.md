# OCI deployment context

Live probes under profile `automq-oci` in `eu-frankfurt-1` on 2026-09-11
exposed an S3 compatibility condition that protects creation but not
replacement. The native OCI API enforced the same conditions. The actual
package storage stage passed scoped credential, synthetic round-trip and
lease probes. No broker launched. OCI rejected every attempted VM allocation. Kafka
acceptance, data continuity and repeated full convergence remain untested.

The [deployment report](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/verification.md) records the assessment. Exact source
pins and the development-override scope are in `pins.md`. Its state,
data and ops buckets are OCI resources owned by the deployment, with the same
lifecycle responsibility as its SSH keypair. The original Vultr policy for
adopting external R2 buckets does not apply. The attempted cluster used
`provider-dns: none` and private-CA TLS. Partial-deletion observations below
apply to that path. They do not verify partial cleanup with a cloud DNS stage.

## A stale `If-Match` PUT succeeds and changes the object

The live S3 compatibility endpoint returned these results for one isolated
object:

| Request | HTTP status | Result |
|---|---|---|
| Initial PUT with `If-None-Match: *` | 200 | Created `first` |
| Competing PUT with `If-None-Match: *` | 412 | Refused the competitor |
| PUT with the current `If-Match` ETag | 200 | Wrote `second` |
| PUT with the now-stale `If-Match` ETag | 200 | Wrote `stale` |
| Final GET | 200 | Returned `stale` |

See [compat-preconditions.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/compat-preconditions.json) in the deployment repository.

A conditional-create test alone therefore misses this failure. The endpoint
rejected a competitor when the object already existed, but accepted an
outdated writer after the object changed. This breaks the expired-lease
replacement contract. Two contenders could both replace the same expired
lease and restart combined broker/controller nodes at the same time.

Do not infer compare-and-swap support from an S3-compatible endpoint, an ETag
in a response, or a successful current-ETag replacement. Require the stale
replacement to fail and read back the object to prove its value survived.
Use the provider's native conditional operation when the compatibility API
cannot enforce the condition, then repeat both allowed and refused writes
through the installed application client.

## Native OCI conditional writes reject the stale replacement

The separate native API probe admitted the first conditional create and the
current-ETag replacement with HTTP 200. It rejected the competing create and
stale-ETag replacement with HTTP 412. The ETag changed after replacement, and
the final object retained `{"value": "second"}`. See
[native-preconditions.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/native-preconditions.json) in the deployment repository.

The native probe establishes the provider operation's behavior. The deployed
restart-lease client must use that operation and pass its own negative probes
before the cluster can rely on it. Read an ETag from the same native API that
will evaluate `If-Match`; do not assume two API endpoints expose interchangeable
ETags. The application identity needs access only to its data and ops buckets.
Its native API signing key and S3 customer secret key belong to that scoped
identity, separately from the operator's state credentials. The actual package
identity passed the isolated checks below.

## The actual package storage identity passed isolated probes

At `14:06:51.558481 UTC`, the package-generated application identity passed
the complete storage probe. Both data and ops buckets returned HTTP 200 for
listing. Synthetic objects survived exact-byte PUT/GET comparison and the
probe deleted them. These were probe objects, not AutoMQ records. See
[storage-stage.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/storage-stage.json) in the deployment repository.

The storage stage completed a second successful real create. Its independent
plan returned exit 0 with no changes. See [storage-stage-repeat.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/storage-stage-repeat.json).
This repetition verifies the isolated storage stage, not a second cluster
converge.

The package's own conditional-precondition command passed. The lease test
admitted its first holder, refused a competitor, and allowed the current
holder to renew. After expiry, a successor acquired the lease. The old holder
could not release it, the successor still excluded another contender, and
the successor could release it.

The operator independently confirmed that the state bucket and ownership
object existed. With the application credential, compatibility API bucket
HEAD, object listing, object GET and object PUT all returned HTTP 404. Native
API object HEAD and PUT also returned HTTP 404. Those paired observations
establish denial for the tested operations, despite OCI's concealed response.
They do not prove denial from the status code alone.

An initial complete precondition check was followed by a transient
`SignatureDoesNotMatch`. A subsequent complete probe passed. The final probe
reported one readiness attempt and 14.7 seconds; that is the duration of that
invocation, not time from credential creation or a propagation guarantee.
A single successful request did not establish that every subsequent request
would authenticate during propagation.

## A new customer secret key does not authenticate immediately

The failed `ListObjectsV2` probe returned `SignatureDoesNotMatch`:

```
The secret key required to complete authentication could not be found. The region must be specified if this is not the home region for the tenancy.
```

The probe already supplied `eu-frankfurt-1` as its signing region. The same
credential began authenticating without configuration changes. See
[credential-propagation.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/credential-propagation.json) in the deployment repository.

The operator created an OCI customer secret key at `13:16:48.537 UTC`.
The last sampled authentication failure occurred at `13:24:03.993 UTC`;
the first successful sample occurred at `13:25:04.035 UTC`.

That first success was 8 minutes 15.498 seconds after creation. The samples
locate propagation between 7 minutes 15.456 seconds and 8 minutes 15.498
seconds. They do not establish an OCI-wide propagation bound or a fixed sleep
that makes future credentials usable.

Keep the generated credential and retry a bounded authentication probe before
starting resource work that needs it. A freshly issued key failing its first
request does not by itself prove that its secret was copied incorrectly.
Keep authentication failures separate from an authenticated user's missing
bucket permissions. Do not expose the secret in retry logs.

## Bucket denial and bucket absence require separate evidence

OCI may conceal a forbidden bucket or object behind HTTP 404. A 404 from the
application credential alone cannot prove either isolation or absence.
Check bucket and ownership-object existence through the operator's native
OCI identity, then probe that same bucket and object with the application
credential. Only the independent existence check lets a refused application
request establish the access boundary.

The audit also needs the instance's boot-volume attachment IDs. OCI-generated
boot-volume names need not carry the deployment profile. Save the IDs before
deletion and use them in the final native inventory after the attachments
have disappeared. A name-only search can miss an orphaned disk.

## Valid shape settings still fail with `Valid ratio range: 0 - 0`

The captured E4 compute attempt requested `VM.Standard.E4.Flex`, 1 OCPU and 8 GiB.
OCI rejected it with:

```
400-InvalidParameter, Invalid ratio of memory in GB to OCPUs. Current ratio: 8.0. Valid ratio range: 0 - 0
```

The independent limit check found zero E4 core and memory limits in all
Frankfurt availability domains. A2 had positive reported limits. Its shape
metadata nevertheless reported both minimum and maximum memory per OCPU as
zero, while also reporting flexible memory and a nonzero default. See
[shape-preflight.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/shape-preflight.json), [a2-shape-options.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/a2-shape-options.json) and
[a2-raw-shape-options.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/a2-raw-shape-options.json) in the deployment repository.

A2 launches with 1 OCPU and 8 GiB, 6 GiB, and omitted memory all failed with
the same zero-range validation. The final A2 attempt requested two vCPUs instead
of OCPUs and failed with the same zero range in all three availability
domains. It reported a current ratio of 6. The 8 GiB attempt reported a current ratio of
4. A2 has two AmpereOne cores per OCPU; that ratio alone does not prove that
the provider doubled the requested OCPU count. The live compute provider was `oracle/oci` 8.4.0.
See [compute-attempts.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/compute-attempts.json) for requested settings and exact errors.

Oracle's [shape documentation](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)
allows flexible A2 memory. The zero range conflicts with those documented
settings. It is not evidence that zero memory is valid, that custom memory
is unsupported, or that a particular alternative ratio fixes the request.
The observations also do not prove that quota caused the A2 validation error.

A1 attempts then returned `500-InternalError, Out of host capacity.` in all three Frankfurt
availability domains. A positive service limit permits allocation but does
not establish available physical capacity. Keep desired-state validation,
image compatibility, account limits and actual allocation results separate.
A rendered plan or compatible image cannot establish that any VM started.

## `IdcsConversionError`: `The primary email must be specified.`

The managed storage stage created OCI resources but failed to create
`oci_identity_user.application` with HTTP 400:

```
IdcsConversionError
The primary email must be specified.
```

The service user needs explicit `automq-oci-user-email`, unique within the
tenancy. Supplying that setting allowed the storage stage to complete. See
[storage-stage-email-error.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/storage-stage-email-error.json) in the deployment repository.
Do not assume that the Terraform provider accepting an omitted `email` means
an Identity Domains tenancy accepts it. Preserve the stage's existing state
when retrying, because the failed user operation does not roll back buckets
or other resources already created.

## A failed initial node create is not an absent node

A provider rejection can leave an empty version-4 state file and a failed
operation in the compute journal. Changing shape settings does not clear that
operation or establish that retrying is safe.

The compute library's explicit OCI recovery operation checks the current
failed operation ID, empty state, and native provider resource absence under
the journal lease before recording a retry. Use its recovery contract at the
pinned source. Do not edit the journal manually or reuse an operation ID from
an earlier failure. A terminating VM or boot volume still prevents recovery.

The native inventory must cover every original availability domain before a
retry changes placement. An OCI CLI invocation with empty stdout does not
prove that the provider returned an empty resource list. Require a successful
JSON array response and all pagination tokens. The recovery helper matches
resource display names, so independently inspect IDs if someone renamed a
resource or moved it outside the original compartment or domain.

## Deletion skips owned resources after a failed VM create

The failed compute attempts still left owned resources. Before deletion, native
inventory found three buckets, one network security group, the application
IAM resources, and both credential types. No VM had launched. See
[resources-before-delete.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/resources-before-delete.json) in the deployment repository.

Recovered nodes in the declared state made compute inspection return an error.
The package treated any managed-backend inspection result other than
`present` as a reason to jump directly to backend finalization. That skipped
application storage, shared compute resources and the SSH key. The finalizer
refused with exit 1:

```
managed backend finalization refused; live or unowned state remains
```

See [delete-lifecycle.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/delete-lifecycle.json). Its refusal protected the backend;
it did not establish that deletion had completed.

An intermediate working-tree retry reached SSH configuration and refused with
`compute cluster unavailable; refusing placeholder inventory`. No resource
destroy stage ran. Host-dependent rendering must not require a running node
when deleting a deployment whose node creates never completed.

After that routing correction, the local SSH updater rejected deletion with
exit 2 and `invalid SSH host inventory`. It still required a nonempty host
inventory for removal. No storage or infrastructure destroy ran. Removing
owned local aliases after a failed create must accept an empty inventory;
creating aliases still requires validated hosts. Keep those event-specific
requirements separate.

Another defect rejected the empty rendered node documents during deletion
even though the failed create had left a validated empty state file. A
never-created node needs no provider destroy operation. It must still follow
the journal and state transition that permits the shared resources to be
deleted.

Only verified absence may select an absent-resource path. An inspection error
is not absence, and recovering a failed create does not remove the resources
that earlier stages created. A partial deployment must delete its owned
application storage and IAM resources, shared network resources and SSH
keypair, then finalize the empty backend last. Keep malformed or unreadable
state failures closed. A successful backend refusal is a safety check, not a
successful deployment cleanup.

## An empty multipart listing stops application cleanup

After SSH cleanup succeeded, deletion stopped at application storage with:

```
managed storage failed; inspect bucket ownership, state access, and provider permissions
```

The verified cause was `oci os multipart list --all` returning exit 0 with
empty stdout. The helper tried to decode the empty string as JSON. Its list
parser now accepts that known successful CLI result as an empty collection,
while command failures and non-list JSON still fail. This CLI-specific
normalization does not replace the native resource-absence proof required by
failed-create recovery.

Before purging objects, the helper also compares the live bucket's immutable
OCID, namespace, compartment, name and ownership tags with its recorded state.
A matching name alone would not identify a bucket someone deleted and
recreated outside the deployment.

With the multipart correction, storage and infrastructure deletion completed.
The subsequent independent inventory found no application buckets, IAM user,
group, policy, customer secret keys, API keys or network security group. The
local SSH private key, public key, lock, known-hosts file and alias were absent.
See [resources-after-resource-delete.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/resources-after-resource-delete.json).

At that intermediate checkpoint, the state bucket still existed and backend
finalization had refused. The successful final retry is recorded below. Resource cleanup and complete lifecycle deletion
are separate claims. The shared subnet and VCN predated this deployment and
remain outside its ownership.

## Bucket update returns 404 because the HTTP method is wrong

The next backend-finalization failure occurred after the ownership marker
recorded `deleting` and the compute journal recorded retirement. No state
versions had been purged. The native bucket-update request used PUT and
returned `404 Not Found` with error code `NotFound`. See
[backend-finalize-error.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/backend-finalize-error.json).

OCI's `UpdateBucket` operation uses POST. An existing bucket can therefore
return 404 when the request uses the wrong method. Confirm the endpoint and
HTTP method against the pinned SDK or provider operation before treating
that response as evidence that the bucket disappeared.

After correcting the method, resume the normal finalization path. Preserve
the ownership marker and retired journal; their deletion phase exists so an
interrupted cleanup can continue. Do not reset them or create a replacement
backend because one operation returned 404.

## A retired journal with a held lease blocks resumed finalization

A normal delete retry then stopped before backend finalization with:

```
compute state unavailable; legacy monolithic state requires explicit migration
```

The journal was valid, matched this deployment's identity and already marked
compute resources retired. The interrupted finalizer still held its lease.
Inspection checked for an idle lease before recognizing retirement, so it
classified that resumable state as unavailable. The message did not establish
that legacy monolithic state existed.

The correction validates journal schema and deployment identity first, then
recognizes retirement before applying the active-journal idle requirement.
A retired journal routes to the guarded finalizer. An active journal with a
held lease still refuses competing work. This ordering allows deletion to
resume without weakening active-operation exclusion or treating arbitrary
held journals as destroyed deployments.

## Normal deletion resumed and removed the state bucket last

The default destruction guard refused with exit 2. After the partial-delete
corrections, normal deletion removed application storage and shared compute
resources, then resumed the interrupted backend finalization. The successful
retry exited 0. Backend finalization took 242.549 seconds, removed the retained
state versions and delete markers, and deleted the state bucket last.

This verifies cleanup of the actual partial deployment. No broker ever
launched, so it does not establish shutdown or cleanup of a running OCI
AutoMQ cluster. The no-DNS/private-CA configuration also does not establish
partial cleanup of a cloud DNS stage.

The final independent inventories after deletion and repeated deletion found
zero deployment buckets, VMs, boot volumes, data volumes, VNICs, public IPs,
network security groups, application users, groups, policies or either key
type. All local SSH ownership artifacts were absent. The borrowed subnet
and VCN both remained `AVAILABLE`. See [resources-after-delete.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/resources-after-delete.json)
and [resources-after-repeat-delete.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/resources-after-repeat-delete.json).

The repeat used published source pins without local library overrides and
exited 0. It kept the already-absent backend absent. Published-pin build and
create dry-run also exited 0. See [delete-lifecycle.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/delete-lifecycle.json) and
[published-validation.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/published-validation.json). These final checks do not substitute
for a successful cluster create.

After confirming state-bucket deletion, the operator revoked the temporary
backend customer secret key and verified its absence through the native API.
See [backend-credential-revocation.json](https://github.com/getcolors/automq-oci/blob/19b1a9e15f1d95bc3db7fe24840015c0e9718251/evidence/backend-credential-revocation.json). The operator's shared OCI
identity and borrowed network remain outside the deployment lifecycle.
