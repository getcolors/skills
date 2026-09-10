# Acceptance doctrine and evidence limits

All evidence filenames refer to
[the AWS deployment evidence directory](https://github.com/getcolors/neon-multi-node-aws/tree/main/evidence).

## Create and external client path

Successful published create3 and create4 ran the server gates and seven external
gates. Independent `public-first-create.txt` and `public-rehearsal-2.txt` add an
exact random persistent witness, yielding eight external gates:

1. Trusted certificate, correct hostname and encrypted PostgreSQL session.
2. Specific wrong-password refusal.
3. Specific passwordless refusal.
4. Specific plaintext HBA rejection.
5. Application role cannot become superuser.
6. Exact original random witness readback.
7. Authenticated write/read of the deterministic smoke row.
8. Entry alias and all five node SSH aliases work.

Server gates also wait for all three safekeepers' commit LSNs to reach the
observed target and require a new WAL object beyond a pre-switch listing.
Existing pageserver objects alone do not prove fresh durability or a particular
RPO. Use the recovery witness evidence to state the tested persistence claim.

`continuity-create-4.json` proves the same five instances, five root volumes and
six container identities survived convergence. This establishes that successful
reconvergence did not quietly replace the database infrastructure.

`storage-first-create.json` proves distinct encrypted, public-blocked S3 buckets,
matching ownership markers and application credentials denied backend listing
and reading. `network-verified-create.json` records role ingress inspection.

## Recovery bought by rehearsals2 and 3

`live-rehearse-2.txt` and `live-rehearse-3.txt` completed successfully. Independent
`recovery-rehearsal-2.json` read three unique acknowledged outage witnesses;
`recovery-final.json` read all six after repeating the fault sequence, covering
safekeeper-0/1/2 twice, through trusted external TLS. The original random external
witness also survived, as checked in `public-final-live.txt`. The successful
task output is retained in `ansible-rehearsal-3.txt`.

The executed faults were compute container recreation, each safekeeper stopped
individually with a write acknowledged while absent, two safekeepers stopped
with no timely acknowledgement, broker restart, and pageserver tenant cache
removal followed by S3 reattachment and compute recreation. A final fault
removed the first safekeeper's local state, rebuilt it empty, and recreated
compute to recover through the two surviving quorum members. This is not an
S3-only safekeeper restore. Safekeepers were
restored in always blocks. The S3 attachment generation reached 2 and then 3.

The third-run trace records no acknowledgement over 45.142796 seconds. The
uncertain no-quorum write was first observed present after rehearsal2 recovery.
The later run reused its identity, so later presence does not prove that third
attempt committed. State the first observation explicitly:
no acknowledgement is the proved gate; rollback was not proved and was not the
observed final state. Repeated identical witness values cannot distinguish an
old surviving write from the latest outage write. The harness records unique
identities and values only after a successful SQL assertion, then the independent
operator verifies those exact pairs after recovery.

The first rehearsal failed before that ledger write because psql command tags
confused the assertion. Its unledgered row was excluded. Successful rerun after
the parser correction is the proof, not reinterpretation of the failed run.

## What this does not establish

There is one availability zone, one compute instance and one pageserver.
The test establishes neither automatic failover for those services nor multi-zone
or region survival. Pageserver cache removal with surviving safekeepers is not
simultaneous loss of all storage disks. No numerical full-storage-loss RPO,
performance claim, sustained load result, or full-cluster disaster recovery
claim follows from these gates. Certificate issuance and use were verified;
future timer-driven renewal is unverified until exercised explicitly.

## Guarded deletion

The committed configuration defaults to compute-prevent-destroy true. The
protected delete refusal is recorded in `delete-guard-final.txt`. Source inspection
confirms current-run writer proof precedes application bucket purge, with DNS
and local aliases removed before compute and backend retirement last.

`live-delete-2.txt` completed the destructive teardown. Independent
`resources-after-delete.json` counted zero remaining deployment resources and
zero billable resources, verified all five recorded root volumes absent, both
buckets absent, and no remaining VPC dependencies, keypairs or scoped IAM users.
Terminated instance records remain as AWS history, not running resources.
`dns-after-delete.json` found no record; `local-after-delete.json` verified the
private/public key files, known-hosts file, managed block and all six aliases gone.

The first delete had safely stopped before cleanup because scaffolding removed
its own execution directory; source583424b corrected that event boundary before
the successful second delete. A later repeated delete still failed because the
already-retired backend produced a different absence signal from a missing state
key. Source418cb97 routes that managed-delete inspection error to the existing
authenticated, owner-checking backend finalizer. `live-delete-4.txt` passed the
repeated delete; `resources-after-repeat-delete.json` again verified zero
resources, zero billable resources, both buckets absent and all five volumes
gone. Final DNS and local absence checks also passed. This is independent
absence verification, not an unconditional success on missing state.
