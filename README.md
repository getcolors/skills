# skills

Agent skills for the [getcolors](https://github.com/getcolors) workspace. They
give coding agents repeatable operating procedures; they are not Colors Package
Skills and do not provision a project from `colors.yml` themselves.

## Skills

| Skill | What it does |
|---|---|
| [`create-package-skill`](create-package-skill/SKILL.md) | Guides an agent through creating a Colors Package Skill and a deployment, with explicit boundaries around credentials, infrastructure changes, and authorization. |
| [`refresh-oci-token`](refresh-oci-token/SKILL.md) | Renews the OCI CLI session token. Extends it in place while it is still valid; falls back to a browser login when it has expired, adding the login URL to the current Emacs server's kill ring so a headless host can complete the flow. |

## Use create-package-skill

Give the skill to your coding agent for its next request:

```sh
npx skills use getcolors/skills@create-package-skill
```

This is the primary way to use it. The command reads the skill directly from
GitHub and prints the instructions for the agent; it does not install files into
the current project.

## Install refresh-oci-token

`refresh-oci-token` includes a script that must remain available after the skill
is loaded, so install it into your personal skills directory:

```sh
cp -r refresh-oci-token/ ~/.claude/skills/
diff -r refresh-oci-token/ ~/.claude/skills/refresh-oci-token/
```

The install is a **copy, not a symlink**. Pulling this repo does not update it.
The script runs under [babashka](https://babashka.org/) and also needs the `oci`
CLI on `PATH`.

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
