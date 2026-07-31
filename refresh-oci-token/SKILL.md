---
name: refresh-oci-token
description: Refresh the OCI CLI session token when it has expired or is about to. Use when a package-skill launcher (`./green`, `./walter`, …) running create/describe, or `tofu plan`, or any `oci` command fails with an authentication or 401 error, when `oci session validate` reports the session expired, or before starting a long create that would outlive the current token. Handles the headless browser login by putting the login URL on the laptop's clipboard with OSC 52.
---

# Refresh the OCI session token

The `DEFAULT` OCI profile on this machine is session-token based, and Oracle
caps a session at **60 minutes**. An expired token does not look like a config
error — it surfaces as an auth failure at plan time, part-way into a `create`.

```sh
bb ~/.claude/skills/refresh-oci-token/refresh-oci-token.clj
```

That is the whole thing. It picks the right path on its own:

| State | What happens |
|---|---|
| Token still valid | `oci session refresh` extends it in place — no browser, nothing to do |
| Token expired | Browser login, because nothing else can renew it |

Options: `--profile NAME`, `--region ID`, `--force` (skip the refresh path),
`--timeout SECONDS` (default 300), `--no-clipboard`.

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

**The URL — automatic.** The script reads the login URL out of the CLI's output
and writes an OSC 52 sequence to the terminal device, which asks the terminal
emulator to set the clipboard. The emulator runs on the laptop, so the URL lands
on the laptop's clipboard, ready to paste into a browser. It is printed as well,
in case the terminal declines.

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

**Nothing on the clipboard.** Paste the printed URL by hand, then look at what
is actually holding the pty. The terminal on this machine is `ghostel` running
inside Emacs (`INSIDE_EMACS=ghostel`), not Ghostty directly — Ghostty is only
the outermost layer, across the SSH connection. Ghostel parses OSC 52 and then
drops it unless enabled:

```elisp
(setq ghostel-enable-osc52 t)   ; nil by default
```

It is off by default on purpose — any command output can then overwrite the
clipboard — and ghostel deliberately keeps OSC 52 out of its bundled terminfo,
so nothing advertises the gap. The failure is completely silent: the sequence
arrives, is parsed, and is discarded. A plain line written to the same device
still shows up, which makes the write path look healthy.

To enable it in a running session without restarting Emacs:

```sh
emacsclient -s "$(echo "$EDITOR" | sed 's/.*-s //')" -e '(setq ghostel-enable-osc52 t)'
```

Elsewhere the usual suspects apply: Ghostty's `clipboard-write` (defaults to
`allow`, so rarely the problem), or tmux needing `set -g set-clipboard on`.

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
