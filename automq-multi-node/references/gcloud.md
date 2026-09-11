# Google Cloud deployment context

Two live converges passed on-host acceptance and all 16 external gates under
profile `automq-gcloud` in project `colors-508307` on 2026-09-11. The second run
used published immutable dependencies with no `LIB_ROOT` overrides. A separate
50-record topic remained byte-identical across that converge. Full deletion,
repeated deletion and the independent final resource audit also passed.

The [deployment report](https://github.com/getcolors/automq-gcloud/blob/c5184d352fbb6467e179137f32ef6913368e8bc0/verification.md)
and its non-secret evidence record these observations. Pins are in `pins.md`.

## Credential boundaries

The native OpenTofu backend uses Google Application Default Credentials.
Coordination journals and lifecycle operations use gcloud OAuth credentials.
The AutoMQ application uses its scoped service account's HMAC credentials with
the custom GCS signer described below. These are distinct authentication paths;
a successful backend read does not establish that the application's XML API
request can authenticate or enforce a generation condition.

## The native state object has a different path

The GCS OpenTofu backend stores the default workspace at
`<logical-tfstate-key>/default.tfstate`. State-presence and ownership probes must
GET that object. The coordination journal remains at its direct key and must
not acquire the state suffix.

The first live bootstrap created the state bucket and then refused to continue
because a state-presence probe still used the S3 transport. A bucket existing
does not prove that its native backend's state discovery works. Diagnose the
transport and exact object name before treating a missing state response as
permission to create replacement resources.

## `not found: 404.` is an observed gcloud absence response

The next run created three VMs, then the application-bucket ownership preflight
refused a gcloud bucket lookup. The command returned lowercase
`not found: 404.` from gcloud version 569.0.0.

The preflight's absence parser did not recognize that response. Its correction
accepts the exact missing-bucket response. Authorization failures and other
errors must still fail closed. A successful compute stage does not establish
that application-bucket creation has begun.

## Keep provider-specific firewall evidence scoped

The pinned Google Ubuntu image reported UFW inactive on the first inspected
host. The original Vultr image shipped UFW active with only SSH allowed.
Do not copy that image observation into a Google diagnosis. The shared
requirement is to test private TCP between brokers and controllers and inspect
both host and provider filtering when the quorum cannot elect.

## Base package installation stalls on the security archive

During create attempt 3, the base apt task remained blocked for 282 seconds.
A 15-second HTTP request to the configured global `security.ubuntu.com`
`noble-security` archive timed out on node 0. The regional endpoint
`http://us-central1.gce.archive.ubuntu.com/ubuntu/dists/noble-security/InRelease`
returned HTTP 200 with signed repository metadata from the same host.

The package added optional `automq-apt-security-mirror`. The deployment sets
it to `http://us-central1.gce.archive.ubuntu.com/ubuntu`; the rewrite preserves
the source's Suites, Components and Signed-By fields. This addresses the
observed archive reachability failure without changing Ubuntu's security suite
or signature verification.

After stopping Ansible, two nodes had completed base package installation and
the remaining apt worker exited naturally. The operator checked all package
locks were free before retrying. Do not infer that a stopped controller has
also stopped its remote apt workers, and do not remove package-manager lock
files to force a retry.

The source fix is AutoMQ `d6e3012`, with launcher publication `ac5b5ee`.
The subsequent Ansible converge completed in 403.924 seconds and passed all
on-host gates. Apt reachability and on-host acceptance remain distinct checks.

## `ExcessHeaderValues` when conditional writes mix header dialects

Live GCS probes returned:

```
ExcessHeaderValues
Requests cannot specify both x-amz and x-goog headers.
```

Boto3's S3 signer adds `x-amz-date` and `x-amz-content-sha256`. Adding
`x-goog-if-generation-match` to that request mixes the two header dialects,
which the GCS endpoint rejected.

Renaming the condition to `x-amz-if-generation-match` did not fix it. GCS
silently ignored that unsupported alias. Both the initial conditional create
and the competing create returned success. HTTP 200 alone therefore proved
that the request succeeded, not that the ownership condition applied. The
operator removed the isolated probe object afterwards.

A live signing probe passed after a custom `S3SigV4Auth` subclass converted the
signing headers to `x-goog` before canonical signing. The request then used one
coherent dialect. The initial create succeeded, the competitor failed, an
exact-generation replacement succeeded, and a stale-generation replacement
failed.

Package source `f0c34f1`, published by launcher commit `f6877e0`, integrates
the signer. Independent probes using the installed package client passed the
lease and generation checks below. These results prove the installed signing
and ownership behavior, not completed deployment acceptance. When
retesting the implementation, require both allowed and refused mutations and
verify the object's final value. A condition that never rejects a competing
writer cannot protect a restart lease or a cluster ownership marker.

## Bucket ownership and conditional mutations

The deployment created state, data and ops buckets as owned lifecycle resources
beside the SSH keypair. Independent inventory verified uniform bucket-level
access, public-access prevention and zero soft-delete retention on all three
buckets. The state bucket enabled versioning.

The [storage probe](https://github.com/getcolors/automq-gcloud/blob/c5184d352fbb6467e179137f32ef6913368e8bc0/evidence/storage-probe.json)
used the deployed application's HMAC credentials and signing client. It found
actual AutoMQ objects in both application buckets after excluding `_colors/`
bookkeeping. State-bucket HeadBucket, ListObjectsV2 and GetObject requests
returned HTTP 403.

An isolated test lease admitted its first holder and refused a competitor.
Expiry permitted takeover, the stale holder could not release its successor's
lease, and that successor still excluded another contender. The current holder
could release it. A raw stale-generation PUT returned HTTP 412 and left the
newer object value intact. The probe removed its own objects afterwards.

## Acceptance and its limits

Both full runs verified the certificate and IP identity on all three public
endpoints, metadata containing three brokers, an exact 200-record public round
trip, a wrong-password refusal and refusal of writes outside the client prefix.
Private-CA certificates carry public IP SANs. Clients trust the exported CA and
retain endpoint identity verification; no DNS provider is involved.

The first targeted outage stopped node 1, which led partition 1. All 100
pre-stop records survived. The second targeted node 1 on partition 0 and again
preserved all 100 records. Both partitions accepted writes two seconds after
`docker stop` completed. The node returned with zero lag and matching log end
offsets, 2069 and 4611 respectively. Checked consumer-group offsets and
controller restart gates passed in both runs. See the
[first acceptance](https://github.com/getcolors/automq-gcloud/blob/c5184d352fbb6467e179137f32ef6913368e8bc0/evidence/acceptance-first.txt)
and [published-pin repeat](https://github.com/getcolors/automq-gcloud/blob/c5184d352fbb6467e179137f32ef6913368e8bc0/evidence/acceptance-second.txt).

A separate 50-record continuity topic retained SHA-256
`861ccd80ab6a46490f760bfc363986c2ffd8e84cd38a6a37862ced645950d40b`
across the second converge. This topic was independent of the acceptance
script's recreated topics.

The timing starts after the stop command returns. It does not measure abrupt
crash, disk-loss or AZ-loss recovery. The consumer-offset gate retains the
placement limitation in `acceptance.md`, so it does not prove forced
coordinator loss. Transactions remain untested.

Short bursts of 20,000 records at 1 KiB reported 1391.594768 and 1452.854860
records/s, with p99 latencies of 11,687 and 10,591 ms. These observations after
fault tests are not sustained capacity benchmarks or production latency
objectives.

## Deletion is a verified lifecycle

The default destruction guard refused deletion with exit 2. Authorized full
deletion and repeated deletion both exited zero. Backend finalization removed
the state bucket last, including the 123 object generations recorded before
deletion. That final stage took 52.457 seconds. See the
[lifecycle evidence](https://github.com/getcolors/automq-gcloud/blob/c5184d352fbb6467e179137f32ef6913368e8bc0/evidence/delete-lifecycle.json).

The [final independent audit](https://github.com/getcolors/automq-gcloud/blob/c5184d352fbb6467e179137f32ef6913368e8bc0/evidence/resources-after-delete.json)
found zero deployment VMs, disks, external addresses, firewalls, networks,
subnets, buckets, soft-deleted buckets, application service accounts or HMAC
identities. The local private key, public key, SSH alias, known-hosts file and
lock were absent. Project API enablement remains project configuration.

Owned buckets follow the deployment lifecycle. The original Vultr policy for
adopted external R2 buckets does not apply to these resources. Successful
cluster acceptance alone would not prove cleanup; the delete runs and
independent inventory establish that separate claim.
