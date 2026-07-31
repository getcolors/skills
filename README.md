# skills

Machine-level agent skills for the [getcolors](https://github.com/getcolors)
workspace — the ones that fix a problem with the *workstation* rather than with a
project.

Each skill is self-contained and depends only on what is on `PATH`. None of them
depend on the Colors SDK, and none are tied to a particular checkout: run them
from wherever you happen to be standing.

## Skills

| Skill | What it does |
|---|---|
| [`refresh-oci-token`](refresh-oci-token/SKILL.md) | Renews the OCI CLI session token. Extends it in place while it is still valid; falls back to a browser login when it has expired, putting the login URL on your laptop's clipboard over OSC 52 so a headless host can complete the flow. |

## Install

Copy a skill into your personal skills directory:

```sh
cp -r refresh-oci-token/ ~/.claude/skills/
```

Claude Code discovers it there and decides to invoke it from the `description` in
the skill's frontmatter.

The install is a **copy, not a symlink** — pulling this repo does not update an
installed skill. After changing or updating one, copy it over again and confirm:

```sh
diff -r refresh-oci-token/ ~/.claude/skills/refresh-oci-token/
```

Scripts run under [babashka](https://babashka.org/). `refresh-oci-token` also
needs the `oci` CLI on `PATH`.

## These are not Package Skills

The Colors stack has a second, unrelated thing called a skill: `package-once-*`
and `package-walter-green`, which ship inside
[`once`](https://github.com/getcolors/once) and
[`walter`](https://github.com/getcolors/walter) and are installed into a
*project* with `npx skills add getcolors/once`. Those converge real
infrastructure from a `colors.yml`, are pinned to a library by git SHA, and are
recorded in a `skills-lock.json`.

Nothing in this repo works that way. A skill here has no lockfile, no pin, and no
desired-state file — it is a script and the prose telling an agent when to reach
for it.

## Adding a skill

```
<skill-name>/
    SKILL.md              frontmatter (`name`, `description`), then the prose
    <skill-name>.clj      the script, when there is one
```

The `description` is routing text: it is all an agent sees when deciding whether
the skill applies, so name the symptoms someone would actually hit — the error
message, the command that failed — rather than describing how the skill works.
Save that for the body.

Scripts should guard their entry point so the file can be loaded without running
anything:

```clojure
(when (= *file* (System/getProperty "babashka.file")) (main *command-line-args*))
```
