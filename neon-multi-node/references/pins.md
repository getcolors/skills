# Verified pins and retest conditions

## Original Green deployment

Verified September 10, 2026, profile neon-multi-node-aws, AWS us-east-1a.
The successful create4 and rehearsals2/3 runtime was package commit
`910862079124a533dfc1f382d888210038c595e7`; launcher commit `a875af5`
stamps it, package `6471951` adds matching rendered fixtures, and published
package `4b9c88e9646c3baf92f8078b93e356714b24b104` records verified behavior.
The later cleanup fix is source `583424b5f695ca2e3a8170b0d2da349f1055bf5b`,
stamped by launcher `4e6d0ed93551b402c9c31c8e0a2478f866979ec2`.
The verified repeated-delete fix is source
`418cb97ebd54d781de1916f2432b2aed078fb981`, stamped by final published launcher
head `0f06fe9de2ab45a026ad7e08476450449d38f88d`.
Its application runtime is unchanged from the live create/recovery source;
cleanup verification is tracked separately in acceptance.md.

| Component | Verified version or immutable pin |
|---|---|
| Neon storage image | `release-9129@sha256:166022a72bf9983eba96d061d794f4740edbd4c3301e66202c1180acce9a323c` |
| Neon compute image | `release-compute-9073@sha256:ed6a613231d7026b4df8b00563444b9f33745370a3b3f0a2183e723f460ba974` |
| Upstream compute source | `98882548d80fdc2e5e28f2ea3c693307587b057e` |
| Actual PostgreSQL server | 17.5 |
| Green SDK | `3f33f5d4dcce1f8d97a11b6972e13eb3f0b37654` |
| colors-compute | `09ec539e75dc21c4dafb019eb8f9da276e695f6f` |
| Reused Neon package | `9f8ccc18e218ea3b6ce293a470afd61b19e81639` |
| ONCE dependency | `10e525ae7c37130ab4d532b91c8d2ead94557cc8` |
| Host | Ubuntu 24.04.4 LTS, AMI `ami-025d99823a4caad37` |
| Machines | Two t3.large and three t3.medium, five encrypted 40 GiB root volumes |
| Host Docker / Compose | 29.1.3 / 2.40.3+ds1-0ubuntu1~24.04.1 |
| Host psql / rclone / certbot | 16.15 / 1.60.1-DEV / 2.9.0 |
| Operator psql | 18.6 |
| Operator Babashka / OpenTofu | 1.13.219 / 1.11.5 |
| Operator AWS CLI / Ansible core | 2.35.11 / 2.20.3 |

Image tags and digests are paired in the deployment's `colors.yml`, and actual
running digests were inspected in `evidence/services-first-create.json`.
Dependency commits are declared in the package's `green/deps.edn`; launchers
are stamped with `bb pin` only after source publication. Upstream compute tag
release-compute-9073 was resolved to the source commit above. Host and client
versions are observed evidence, not promised future apt resolution.

Evidence: `database-version.txt`, `host-versions.txt`, `operator-versions.json`,
`live-create-4.txt`, `live-rehearse-2.txt`, `continuity-create-4.json` in the
[deployment evidence directory](https://github.com/getcolors/neon-multi-node-aws/tree/main/evidence).
Server, host-client and operator-client versions differ; do not substitute one
for another.

On an image or certificate-tool change, retest native TLS, real issued
certificate readability, hostname verification, plaintext/auth rejection,
compute recreation and recovery. Before reviving the experimental TLS helper,
re-read both its feature gate and certificate/key parser and test the actual
issued certificate. A schema check alone did not discover either live defect.
On psql changes, rerun realistic RETURNING/command-tag tests and the live
read-only transaction probe. On compute/storage changes, rerun role isolation,
backend credential denials, protected deletion and complete absence audits.
Claims are unknown after their relevant pins move until these gates pass again.

## Later native Red and Blue qualification

The September 10 native Red/Blue create, both same-profile handoff orders and
both recovery rehearsals, protected deletion and complete cleanup use application
source `038e93d524552ef36fb0fff5f306352e68283bff` and launcher bootstrap fix
`62e63a7a63ae5c5ab46cbb73b8dad06d14ab0734`. Later package head
`5208bc1c02c916582d93d6152d0e4e4404c10d6f` changes tests, not that application pin.
Red SDK is `7636bee6a7575485ebaf621f4b1834bdcea59738`; Blue SDK is
`e29a7fc5a7a2895eacb882fc65520c2cdbab96c9`. colors-compute and both Neon
image digests remain those above. Dependency manifests and overrides must agree.

Observed operator Bun was 1.3.10 and uv was 0.12.6 on aarch64; other operator
versions match the original table. See `evidence/red-blue/operator-versions.json`
and [runtime boundaries](runtimes.md) for the distinction between live create
proof, offline subprocess regressions and offline cold-cache qualification.
