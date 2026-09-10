# Runtime and ownership contracts

## TLS source authority

The source investigation used upstream Neon commit
`98882548d80fdc2e5e28f2ea3c693307587b057e`, corresponding to release-compute-9073:

- [`compute.rs::tls_config`](https://github.com/neondatabase/neon/blob/98882548d80fdc2e5e28f2ea3c693307587b057e/compute_tools/src/compute.rs#L2015)
  drops the optional TLS configuration without the experimental feature.
- [`ComputeFeature` serialization](https://github.com/neondatabase/neon/blob/98882548d80fdc2e5e28f2ea3c693307587b057e/libs/compute_api/src/spec.rs#L198)
  explains the snake_case feature spelling.
- [`tls.rs::verify_key_cert`](https://github.com/neondatabase/neon/blob/98882548d80fdc2e5e28f2ea3c693307587b057e/compute_tools/src/tls.rs#L91)
  implements the observed certificate signature/key parsing restriction.
- [`config.rs` optional TLS block](https://github.com/neondatabase/neon/blob/98882548d80fdc2e5e28f2ea3c693307587b057e/compute_tools/src/config.rs#L105)
  and [cluster settings append](https://github.com/neondatabase/neon/blob/98882548d80fdc2e5e28f2ea3c693307587b057e/compute_tools/src/config.rs#L173)
  show why native PostgreSQL SSL settings can be supplied without the helper.

The final package owns native SSL settings in
`green/src/resources/io/github/getcolors/neon_multi_node/tools/ansible/compute-spec.json`.
Its sibling `runtime.py` renders that specification and owns mounts and HBA policy.
The certificate/key directory is readable by the container user; the host files
are private. The issued certificate was successfully exercised through native
PostgreSQL `sslmode=verify-full` with the public hostname and trusted CA bundle.
Cloudflare's record is DNS-only. PostgreSQL is not an HTTP origin behind its
ordinary proxy.

SSL enabled does not itself forbid plaintext. The package owns the HBA policy
and tests a specific HBA rejection for a plaintext client. Wrong-password,
passwordless and privilege-escalation probes require their expected refusal,
not merely a nonzero client exit. An unreachable server cannot pass them.

## Storage and reattachment

`colors-compute` owns compute/network, SSH keypair and managed backend lifecycle.
The package owns a distinct application S3 bucket and scoped IAM identity.
The actual live identity was denied both listing and reading backend state.
Credentials remain in encrypted backend state and private host files; the
Context Skill must not copy them or the deployment's environment files.

The inherited `neon-r2-*` option names select native AWS S3 here. Inspect the
actual endpoint, region and client provider behavior instead of assuming R2
from those names. The verified deployment used native AWS requests through
rclone, separate pageserver and safekeeper prefixes, and no object expiry rule.

Bootstrap ownership markers distinguish interrupted initialization from a ready
owned prefix. A generation counter is persisted before pageserver attachment.
The tested cache-loss recovery advanced that counter from 1 to 2 and then 3 across repeated rehearsals and retained
acknowledged data with safekeeper WAL still available. The package's
`bootstrap.sh` is the implementation authority; this skill carries no copy.

## Current-run deletion evidence

Source review: `storage.clj::writer-proof?` requires the exact expanded topology
node set in current-run writer-stop evidence before managed storage deletion.
The cleanup play stops owned containers and independently queries Docker.
Deleting the bucket based on a stale marker, a success-shaped Ansible invocation,
or only some of the five machines violates that contract. The Terraform backend
must outlive the resources and credentials whose state it holds.

Deletion verification status is recorded in [acceptance](acceptance.md).
