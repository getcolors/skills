---
name: refresh-oci-token
description: Refresh the OCI CLI session token when it has expired or is about to. Use when a package-skill launcher (`./green`, `./red`, or `./blue`) running create/describe, or `tofu plan`, or any `oci` command fails with an authentication or 401 error, when `oci session validate` reports the session expired, or before starting a long create that would outlive the current token. Handles the headless browser login by adding the login URL to the current Emacs server's kill ring.
---

# Refresh the OCI session token

The `DEFAULT` OCI profile on this machine is session-token based, and Oracle
caps a session at **60 minutes**. An expired token does not look like a config
error — it surfaces as an auth failure at plan time, part-way into a `create`.

Run the script relative to the directory containing this `SKILL.md`:

```sh
bb refresh-oci-token.clj
```

Resolve that relative path against the loaded skill's location before running
it. Do not assume a particular agent's install root: Claude Code may load it
below `~/.claude/skills`, Pi below `~/.pi/agent/skills`, and either path may
itself be a symlink.

That is the whole thing. It picks the right authentication path on its own:

| State | What happens |
|---|---|
| Token still valid | `oci session refresh` extends it in place — no browser, nothing to do |
| Token expired | Browser login, because nothing else can renew it |
| `~/.oci/config` or the requested profile is missing | First-time browser login; pass `--region ID` because there is no configured region to infer |

Options: `--profile NAME`, `--region ID`, `--force` (skip the refresh path),
`--timeout SECONDS` (default 300).

A missing `~/.oci/config` does **not** mean the OCI CLI is uninstalled. If the
script reports that `oci` is on `PATH` but no configuration exists, bootstrap
the `DEFAULT` session through the same safe URL-handling flow:

```sh
bb refresh-oci-token.clj --region <oci-region>
```

Use the deployment's OCI region when it is available in desired state or
Terraform configuration; otherwise ask the user for it. Do not run bare
`oci session authenticate`: unlike this script, it prints the login URL to the
terminal instead of transferring it only through the current Emacs clipboard.

`oci session authenticate --no-browser` is **not** a way to avoid the browser.
It calls the token API with the credentials the profile already has, which on an
expired session are the expired ones.

This is a machine-level concern, not a project one: it is the same `~/.oci/`
session whichever project you are standing in. Run it from anywhere. It needs
`oci` on PATH, which in practice means inside a `devenv shell` or a directory
where `direnv allow` has been run.

## The browser login, from a headless box

This host has no display and no browser; you are on it over SSH. Two things have
to cross to the laptop, and only one of them is automatic.

**The URL — automatic.** The script reads the login URL out of the CLI's output,
parses the current server from `$EDITOR` (`emacsclient -s <server>`), and asks
that Emacs to evaluate `kill-new`. The URL lands in its kill ring and, through
Emacs's clipboard integration, on the laptop's clipboard ready to paste into a
browser.

The clipboard is the **only** channel. The URL is never printed — not on any
path, not under any flag, and there is no option that changes this. Before
starting the OCI login, the script verifies that `$EDITOR` names an Emacs server
with `-s` or `--socket-name` and that the server answers. A missing command,
missing server, or failed `kill-new` is fatal rather than a fallback to the
screen; if the failure happens after OCI starts, the login process is cancelled.

**Port 8181 — yours to arrange.** The login redirects to
`http://localhost:8181`, and `localhost` is resolved by the browser, on the
laptop. Without a forward the login succeeds in the browser and the token never
comes back, and the script sits there until it times out. Connect with:

```sh
ssh -L 8181:localhost:8181 <this-host>
```

Worth making permanent in the laptop's `~/.ssh/config`:

```
Host <this-host>
    LocalForward 8181 localhost:8181
```

The forward has to exist *before* the login completes in the browser. Adding it
mid-flow does not work — start a second SSH session with the forward, then re-run.

## When it does not work

**`~/.oci/config` or the requested profile is missing.** This is a first-time
setup, not evidence that OCI CLI is missing. Re-run with `--region ID`; the
script will create the session profile through browser authentication. If the
region cannot be determined from the project, ask the user.

**`$EDITOR` does not name a server.** Run this from a shell started by the
current Neoemacs instance. Its `$EDITOR` has the form `emacsclient -s <server>`;
the per-process server name is what prevents the script from handing the URL to
a different Emacs instance.

**The Emacs server is unavailable.** The script checks it before starting OCI
and aborts without printing the URL. Start the server or use a shell belonging
to a live Neoemacs instance, then re-run.

**Emacs accepted `kill-new`, but nothing reached the laptop clipboard.** There
is no printed copy to fall back on. Fix the current Emacs instance's clipboard
integration, then re-run; the script can verify the server evaluation, but not
the laptop clipboard itself.

**Timed out waiting for the redirect.** Almost always the missing forward. The
browser tab will be sitting on a connection error after an otherwise successful
login.

**Port 8181 already in use.** An earlier run is probably still waiting.
`ss -lptn 'sport = :8181'`, kill it, retry.

**Recovering a login whose redirect had nowhere to go.** The token is in the
address bar of that failed tab, in the fragment after `#`. With the script still
waiting and the forward now up, replaying it on this host finishes the flow:

```sh
curl -s "http://localhost:8181/token?<everything after the # in the address bar>"
```

That endpoint is what the CLI's own callback page calls; it is read from the CLI
source rather than tested, so treat it as a last resort before simply re-running.

## Afterwards

The script reports the new expiry. To confirm independently:

```sh
oci session validate --profile DEFAULT --local   # --local: offline, and does not prompt
```

Plain `oci session validate` asks "Do you want to re-authenticate?" when it
fails, which hangs any non-interactive caller. Always pass `--local`.

From inside a project, its own launcher's read-only command exercises the real
credentials end to end — `./green describe` in once-colors, and the equivalent
elsewhere.

Only `create`/`delete` need credentials at all — `build` and `--dry-run` render
from desired state and work fine with a dead token.
