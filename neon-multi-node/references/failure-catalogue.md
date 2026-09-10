# Failure catalogue

Evidence paths below belong to
[getcolors/neon-multi-node-aws/evidence](https://github.com/getcolors/neon-multi-node-aws/tree/main/evidence).

## SSL required but disabled

Verbatim client symptom: `server does not support SSL, but SSL was required`.
The diagnostic server setting was `off`; compute and storage processes existed.
First create ended with `FAIL RuntimeError: condition timed out: RuntimeError`.

`compute_ctl_config.tls` alone did not activate the helper. At the pinned
source, `compute.rs::tls_config` returns None without `TlsExperimental`, encoded
as `tls_experimental` in the feature list. Enabling that feature exposed the
next failure, so it is a diagnostic explanation, not the final remedy.

Evidence: `tls-required-before-fix.txt`, `tls-feature-gate-before.txt`,
`live-create-1.txt`. Final native PostgreSQL TLS passed `live-create-3.txt` and
`live-create-4.txt` with external certificate and plaintext checks.

## Unknown TLS key type

Verbatim compute log: `could not create key file error=unknown TLS key type`.
Client symptom: `server closed the connection unexpectedly`.
Issued certificate observation: `Signature Algorithm: ecdsa-with-SHA384`.

The helper's `tls.rs::verify_key_cert` matches the certificate signature OID
against ECDSA_WITH_SHA_256 and parses a SEC1 P256 key. The real certificate
failed that path. Reissuing blindly or changing firewall rules does not address
this demonstrated parser mismatch. The accepted solution supplies PostgreSQL's
native SSL settings with the mounted certificate and key and omits the
experimental helper. It retains explicit HBA plaintext rejection.

Evidence: `tls-helper-key-type-failure.txt`,
`certificate-signature-algorithm.txt`, `live-create-2.txt`; successful external
TLS in create3/create4. Source links and configuration ordering are in
[contracts](contracts.md).

## Assertion after an acknowledged INSERT

Verbatim rehearsal symptom: `FAIL AssertionError:` after stopping safekeeper-0
and running its outage INSERT. psql can output the returned value followed by
`INSERT 0 1`; the harness took the final stdout line.

Read-only diagnosis found one outage row but no witness ledger. The same
helper returned `ROLLBACK` for a read-only transaction containing SELECT 1.
The INSERT had succeeded; the subsequent assertion prevented ledger recording.
This was not evidence of data loss, and the unledgered row was excluded from
recovery proof.

Source commit `9108620` adds psql `-q`, suppressing command tags while preserving
returned tuples and errors. The identical live read-only probe then returned
`1`; the complete new rehearsal passed with three exact, unique outage
witnesses. Do not silence the assertion or accept a constant old row.

Evidence: `live-rehearse-1.txt`, `rehearsal-parser-diagnosis.txt`,
`recovery-rehearsal-2.json`. Runtime tests include realistic trailing command-tag
output, rather than mocks that only emit the desired value.

## Timed-out write present after recovery

Observed situation: the two-member outage test received no successful write
acknowledgement before its client timeout; after quorum restoration the
`uncertain-quorum` row was present with value `possibly-committed`.

A timeout bounds observation, not transaction outcome. Keep the no-ack gate
separate from rollback claims. Reconcile the transaction identity after
recovery; do not report a rolled-back write solely from client timeout.

Evidence: successful `live-rehearse-2.txt` plus independent
`recovery-rehearsal-2.json`, whose `uncertain_write_observed.present` is true.
The detailed third-run `ansible-rehearsal-3.txt` records the exact
`PASS no write acknowledgement without quorum; transaction outcome uncertain until recovery`
result after 45.142796 seconds. The third run reused the uncertain row identity;
its later presence alone cannot establish whether that particular repeated
attempt committed. It does independently repeat the bounded no-ack gate.

## Offline build traps

These were offline convergence findings, not runtime outages:

- `invalid compute ingress`: the topology called source-cidrs with the wrong
  application key. Pass the actual ssh-sources/postgres-sources key.
- `template not found on classpath: io/github/getcolors/neon-multi-node/tools/storage/main.tf`:
  resource lookup preserves hyphens. The resource directory is
  `neon_multi_node`; ordinary Clojure namespace munging does not fix the path.

Provenance: the build-session harvest; final source topology/resource keywords
and offline build tests implement the corrections. These failures preceded
live create and are not evidence of provider behavior.

## Ansible exists but cleanup reports ENOENT

Verbatim symptom: `Cannot run program "ansible-playbook"` followed by
`Exec failed, error: 2 (No such file or directory)` and the rendered Ansible
working-directory path. The binary existed. Green scaffold had received
`:green/event :delete`, so its documented behavior removed the target files
before the process tried to start in that directory.

The fix in source `583424b` materializes cleanup files under an explicit build
event, then restores the original delete event for workflow behavior. A real
filesystem regression checks those files exist before execution. The first
attempt stopped before writer/resource mutations; the second delete completed.

Evidence: `live-delete-1.txt`, `live-delete-2.txt`. Source authority:
[Green scaffold](https://github.com/getcolors/green/blob/3f33f5d4dcce1f8d97a11b6972e13eb3f0b37654/src/green/scaffold.clj#L74)
and the companion package's `tools.clj::run-play`. Check the subprocess cwd as
well as the executable when ENOENT follows an artifact lifecycle transition.

## Repeat delete reports migration after complete cleanup

Verbatim repeat-delete symptom:
`compute state unavailable; legacy monolithic state requires explicit migration`.
The backend request separately reported:
`An error occurred (NoSuchBucket) when calling the GetObject operation: The specified bucket does not exist`.

The managed backend had already been retired successfully. The pinned compute
journal reader classified NoSuchKey as absence but NoSuchBucket as an inspection
error. The generic migration message therefore did not establish legacy state.

The package fix routes this managed-delete inspection error to the existing
backend finalizer, which authenticates the AWS account and checks the expected
bucket owner. It proves an absent bucket or validates owned, retired, empty
state before finalization. It does not blindly equate inspection errors with
successful deletion. Access denial, foreign ownership and live references must
still fail closed; ordinary external-backend and inspection operations retain
their existing behavior.

Evidence: `live-delete-3.txt`, `journal-after-retirement.txt`, successful
`live-delete-4.txt`, and `resources-after-repeat-delete.json`. The fix is source
`418cb97`; final package tests include 14 Clojure tests/96 assertions and eight
runtime tests. Source contract: colors-compute's `compute_journal.clj` and
`compute_managed_backend.clj`, plus the companion's `workflow.clj::start-step`.
