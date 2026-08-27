# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`getcolors/skills` holds **Agent Skills** for the workspace, of two kinds.
**Generic skills** carry a procedure: some fix a workstation problem;
`create-package-skill` supplies the guarded workflow for creating a Colors
Package Skill and its deployment; `create-context-skill` distills a verified
build into a Context Skill; `submit-package-skill` and
`submit-context-skill` govern catalog admission. **Context Skills**
(`agent-network-single-node`, `posthog-single-node`, `rybbit-single-node`)
carry knowledge distilled from a verified build — symptom-routed traps,
contracts, and acceptance doctrine. The normative definition, the five
required artifacts, and the no-second-copy rule live in
`workspace/standards/context-skill.md`; `agent-network-single-node` is the
reference implementation, and all three conform — the posthog and rybbit
skills migrated their `assets/` out on 2026-08-27 (rybbit's one verified
improvement, the UDP 443 HTTP/3 publication, was upstreamed to
`getcolors/rybbit` first). Neither kind is a
Package Skill, and none depend on green/red/blue at runtime.

Read `../CLAUDE.md` first. This checkout sits inside the `~/code/getcolors`
workspace, and what that file says about the stack, `COLORS_PAR_*`, profiles and
the shared OCI tenancy is the context these skills act on.

### Not the Package Skills

`once/skills/` and `walter/skills/` also contain things called skills. They are a
different mechanism and nothing here applies to them:

| | this repo | `once/skills/`, `walter/skills/` |
|---|---|---|
| Named | `create-package-skill`, `refresh-oci-token` | `package-once-green`, `package-walter-green` |
| Scope | an agent workflow or workstation operation | one project's desired state |
| Main use | `npx skills use getcolors/skills@create-package-skill` | `npx skills use getcolors/<pkg>@<skill>` |
| Persistent install | only when a skill needs local files, such as `refresh-oci-token` | `.agents/skills/` via `npx skills add` |
| Ships | instructions and, optionally, a standalone script | a launcher that resolves a SHA-pinned library |

## Layout

```
<skill-name>/
    SKILL.md              YAML frontmatter (`name`, `description`), then prose
    <skill-name>.clj      the script, when there is one (generic skills)
    references/           on-demand documentation (Context Skills: pins,
                          failure catalogue, API contract, acceptance)
    evals/                user-in-trouble prompts — the regression net
    assets/               working files; disqualifying for a Context Skill
                          whose companion Package Skill exists
```

`description` is **routing text, not documentation**. It is the only thing an
agent reads when deciding whether to invoke the skill, so it names symptoms —
`401`, `session expired`, the commands that fail — rather than describing the
mechanism. The prose body is what gets read afterwards. The Agent Skills spec
caps it at 1024 characters and `npx skills-ref validate <dir>` enforces that;
when a symptom index outgrows the cap, the highest-signal symptoms stay in the
description and the full index moves to the top of the body
(`agent-network-single-node` shows the pattern).

## Using create-package-skill

Use `npx skills use getcolors/skills@create-package-skill`. It fetches the
workflow from GitHub and prints it for the agent's next request; it deliberately
does not install anything in the current project.

## The installed refresh-oci-token copy is separate

The installed skill is not this checkout. **Editing here changes nothing the
agent runs** until the skill is reinstalled or copied over. The install root is
agent-specific: Claude Code commonly uses `~/.claude/skills/`, while Pi uses
`~/.pi/agent/skills/`; either may point through a shared directory or symlink.
Check the location reported by the agent before updating or comparing it.

A `SKILL.md` must therefore refer to its script relative to the loaded
`SKILL.md`, not hard-code an agent-specific install root. Agents are expected to
resolve that relative reference against the skill directory before invoking the
script.

## Commands

No build, no test suite, no package manifest. Verification is running the thing:

```sh
bb refresh-oci-token/refresh-oci-token.clj --help      # parses, loads, exits 0
```

Scripts are babashka (`bb`, via asdf). `refresh-oci-token` also needs `oci` on
`PATH`, which comes from nix here — so run it inside `devenv shell`, or from a
directory where `direnv allow` has been run.

Every script guards its entry point:

```clojure
(when (= *file* (System/getProperty "babashka.file")) (main *command-line-args*))
```

so the file can be loaded and its functions exercised without firing the side
effect — which for `refresh-oci-token` is a browser login. Keep the guard when
adding a script.

## `refresh-oci-token`

Renews the session-token-based `DEFAULT` OCI profile that `once-colors/` and
`walter-oci/` share. Oracle caps a session at 60 minutes and an expired token
surfaces as an auth failure part-way into a `create`, not as a config error.
Valid token → `oci session refresh` in place; expired → browser login, with the
URL added to the current Emacs server's kill ring because this host is headless.

The script's header comment and the "When it does not work" section of its
`SKILL.md` explain every workaround in it. Read them before touching the
following, all of which look like dead weight and are not:

- `$EDITOR` is tokenized and its `-s` / `--socket-name` is required — several
  Emacs instances can run, and the current shell must choose the one that owns
  its clipboard path
- the Emacs server is checked before OCI starts, and a failed `kill-new` cancels
  OCI — the URL is never printed, so there is no useful fallback
- empty stdin on every `oci` call, and `--local` on every `session validate` — a
  prompt with no reader behind it hangs the caller
- ANSI stripping — the CLI paints an alternate-buffer progress screen even when
  its output is a pipe

`oci session authenticate --no-browser` is not a way around the browser; it
reuses the credentials the profile already has, which on an expired session are
the expired ones.

## Documentation

`index.html` is this repository's landing page and carries two analytics tags:
GA4 measurement ID `G-4VKP1WY4QJ`, whose explicit `page_title` must exactly
equal the decoded HTML `<title>` and stay distinct and stable so one Analytics
property can separate repositories, and the self-hosted Rybbit snippet
`<script src="https://rybbit.getcolors.ai/api/script.js" data-site-id="9fb9c41a6d49" defer></script>`,
which shares one site ID across every page because `getcolors.github.io/<repo>/`
paths already encode the repository. Never add one tag without the other.

## Git

Ordinary single-repo git — no SHA pins, no cross-layer coordination, so nothing
like `bb pin`. Work on the current branch and do not commit or push unless
explicitly asked. Pushing updates what a subsequent `npx skills use` reads. It does not update an
installed `refresh-oci-token` copy; that skill is only live locally once copied.
