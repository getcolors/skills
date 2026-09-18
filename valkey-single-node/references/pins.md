# Verified versions and decay

Verified on 2026-09-18 against one Vultr deployment, subsequently deleted
with explicit user authorization while preserving shared storage. The authoritative
record is private [versions.json](https://github.com/getcolors/valkey-vultr/blob/main/evidence/versions.json),
with runtime observations in private [live-audit-2.txt](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-2.txt).

| Component | Exact version or revision |
|---|---|
| Server | Valkey 9.1.2 |
| OCI image | `docker.io/valkey/valkey:9.1.2@sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d` |
| AMD64 manifest | `sha256:67878c70fc179bb928b1a9b510860aff1c475ff245e91d98d4b2133326bf8e3e` |
| Recorded Valkey source | `7f1dffedff6de73058b2c2a389422b6ecd56c8fb` |
| Package implementation | `1382f8ccea99bcf21696e5a3c7ba6b0146a77bc7` |
| Installed package payload | `0e1892258c8294fa68c661b11bd178408274672d` |
| Green SDK | `3f33f5d4dcce1f8d97a11b6972e13eb3f0b37654` |
| colors-compute | `ae28ea74962bb1897fa6365c143c1d43ac1fe095` |
| Host OS observed | Ubuntu 24.04.5 LTS |
| Host Docker observed | 29.1.3 |
| Host Compose observed | 2.40.3+ds1-0ubuntu1~24.04.1 |
| Host rclone observed | 1.60.1-DEV |
| Workstation Valkey CLI | 9.1.0 |
| getcolors/skills workflow revision | `3c82f5c9fc1400f748988e8295ab3af7cf5994d5` |
| Workspace standard revision | `44f42f7370496f0a51e6ebfaa20143bbabe41ffe` |
| Redis companion reference revision | `520e2613d848ec65afed33dfeab2cbd6c47465aa` |
| cursor/plugins unslop revision | `e31650eea443aaea1e84cc15d88c13f40080b275` |

## Pinning rules used

The deployment names an exact Valkey version and immutable OCI index digest;
the resolved AMD64 manifest is recorded separately. Runtime `server_name` and
`valkey_version` must match the desired identity. The Redis compatibility
field is not the version gate. The package implementation and payload are
separate commits because the payload stamps the already published
implementation SHA. SDK and compute dependencies are immutable git SHAs.

Host packages were installed from the selected Ubuntu repositories and their
actual versions recorded after convergence; they are **observed versions,
not immutable apt pins**. The workstation CLI is deliberately recorded
separately from the server. No claim here equates those versions.

## Retest conditions

On an image bump, repeat authentication reply/exit probes, exact identity,
UID/config permissions, configuration readback, graceful restart, RDB stream
verification, and scratch restoration with AOF off **and** AOF on. The
empty-restore behavior is unknown at another pin until reproduced there.

On Docker/Compose changes, repeat listener and external refusal probes,
container identity across converges, and complete buffered audits with terminal
sentinels. On rclone or retention changes, rerun failure-injection tests and
backup/marker readbacks. The necessity of the R2 flags remains unknown unless
an explicitly authorized comparison establishes it.

On a compute or SDK pin change, repeat both SSH-mode offline contracts,
credential-free rendering, live convergence and stable-resource identity
checks. Repeat the authorized destroy, provider/local SSH absence and
repeat-delete checks at the new pin; they passed at this pin. Shared bucket
preservation must be checked separately from compute deletion. No managed
bucket destruction or destructive backup-retention claim follows from it.
