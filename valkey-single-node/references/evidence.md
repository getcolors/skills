# Harvest and claim-to-evidence map

Harvested after the retained deployment passed its live gates on 2026-09-18.
All links below target the **private** deployment repository; sanitized
excerpts are retained in the failure catalogue and acceptance document.
No credentials, account endpoints or instance addresses are needed here.

| Claim or finding | Primary evidence | Classification |
|---|---|---|
| Both full create workflows reached acceptance and exited zero | [create-1](https://github.com/getcolors/valkey-vultr/blob/main/evidence/create-1.txt), [create-2](https://github.com/getcolors/valkey-vultr/blob/main/evidence/create-2.txt) | Live |
| Healthy describe twice | [describe-1](https://github.com/getcolors/valkey-vultr/blob/main/evidence/describe-1.txt), [describe-2](https://github.com/getcolors/valkey-vultr/blob/main/evidence/describe-2.txt) | Live |
| Recovery rehearsal succeeded | [rehearse-1](https://github.com/getcolors/valkey-vultr/blob/main/evidence/rehearse-1.txt) | Live |
| Identity fields, refusal replies/statuses, listener, file permissions, UID, runtime packages, timer/monitor status, manifest and marker | [first complete audit](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-1-complete.txt), [second audit](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-2.txt) | Live |
| AOF-on loads zero versus two keys with AOF off | [initial comparison](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-1.txt), [second comparison](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-2.txt) | Deliberate live scratch reproduction; initial audit's unrelated application checks remained incomplete |
| First audit stopped after identity; first fix stopped after monitor | [initial partial audit](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-1.txt), [partial fix](https://github.com/getcolors/valkey-vultr/blob/main/evidence/live-audit-1-fixed.txt), [recorded audit diagnosis](https://github.com/getcolors/valkey-vultr/blob/main/verification.md) | Live audit failure, subsequently fixed; partial sections cannot prove skipped checks |
| Password remained unchanged | [password comparison](https://github.com/getcolors/valkey-vultr/blob/main/evidence/password-idempotence.txt) | Live; fingerprints compared privately, not published |
| Provider/container identity stable; buckets readable; non-Valkey backup metadata unchanged; unrelated state changed | [identity and isolation](https://github.com/getcolors/valkey-vultr/blob/main/evidence/identity-and-isolation.txt) | Live; explicitly bounded observation |
| Protected deletion refused | [delete guard](https://github.com/getcolors/valkey-vultr/blob/main/evidence/delete-guard.txt) | Live guard only |
| Exact build/workflow revisions | [versions](https://github.com/getcolors/valkey-vultr/blob/main/evidence/versions.json) | Recorded immutable revisions plus observed runtime versions |
| Retention fail-open, shell/YAML interpolation, public-probe tool-error ambiguity, password argv exposure and ignored monitor result fixed before deployment | [recorded review findings](https://github.com/getcolors/valkey-vultr/blob/main/HANDOFF.md) | Offline inspection/regression findings; no destructive live retention fault injection |

## Deviations retained from the harvest

- The older package workflow named ONCE compute integration; the current
  workspace standard required colors-compute. The build used the pinned
  colors-compute dependency.
- A copied Redis golden asserted an AWS application storage branch outside
  this scope. The corrected gate requires Cloudflare and the retained R2 flags.
- Retention stopped automatically deleting incomplete sets after failure
  injection showed that a swallowed read error could cause deletion.
- Monitor errors became converge failures; auth secrets moved out of command
  arguments; value validation and public-probe outcome classification tightened.
- The audit needed a second stdin fix because a nested monitor exec still
  inherited its script stream. Only buffered, sentinel-complete runs counted.
- The broad unchanged-state assertion failed during concurrent account work.
  It was narrowed to the supported identity and non-Valkey backup observations;
  unrelated resources were preserved.
- The deployment was retained; the only live deletion test exercised its guard.

No upstream documentation/source disagreement was established during this
harvest. No source-function authority is claimed for a contradiction. The
behavioral discoveries are bounded by the pinned live observations above.
