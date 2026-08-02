# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`getcolors/skills` holds **machine-level agent skills** — ones that fix a problem
with the workstation rather than with a project. Each is self-contained: it
depends on what is on `PATH`, never on green/red/blue.

Read `../CLAUDE.md` first. This checkout sits inside the `~/code/getcolors`
workspace, and what that file says about the stack, `COLORS_PAR_*`, profiles and
the shared OCI tenancy is the context these skills act on. This repo is not in
its repository map yet.

### Not the Package Skills

`once/skills/` and `walter/skills/` also contain things called skills. They are a
different mechanism and nothing here applies to them:

| | this repo | `once/skills/`, `walter/skills/` |
|---|---|---|
| Named | `refresh-oci-token` | `package-once-green`, `package-walter-green` |
| Scope | the machine — one `~/.oci/` session, whichever project you stand in | one project's desired state |
| Installed to | `~/.claude/skills/<name>/`, by hand | `.agents/skills/` in a consumer project, by `npx skills add getcolors/<pkg>` |
| Provenance | none — no lockfile, no SHA pin | `skills-lock.json`, source and content hash |
| Ships | a standalone script | a launcher that resolves a SHA-pinned library |

## Layout

```
<skill-name>/
    SKILL.md              YAML frontmatter (`name`, `description`), then prose
    <skill-name>.clj      the script, when there is one
```

`description` is **routing text, not documentation**. It is the only thing an
agent reads when deciding whether to invoke the skill, so it names symptoms —
`401`, `session expired`, the commands that fail — rather than describing the
mechanism. The prose body is what gets read afterwards.

## The installed copy is a copy

`~/.claude/skills/<name>/` is a separate directory holding the same bytes, not a
symlink into this checkout (verified by inode). **Editing here changes nothing
the agent runs** until it is copied over:

```sh
cp -r refresh-oci-token/ ~/.claude/skills/
diff -r refresh-oci-token/ ~/.claude/skills/refresh-oci-token/   # should be silent
```

Same trap the workspace has with package launchers, and it fails the same silent
way: the agent keeps running the old version while the checkout looks right. Run
the `diff` before concluding a change did not take effect.

Because of this, a `SKILL.md` documents the **installed** path
(`bb ~/.claude/skills/…`) rather than a path in this checkout. That is deliberate
— leave it.

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

## Git

Ordinary single-repo git — no SHA pins, no cross-layer coordination, so nothing
like `bb pin`. Work on the current branch and do not commit or push unless
explicitly asked. Pushing here does not update anything: the agent still reads
`~/.claude/skills/`, so a change is only live once copied.
