---
name: clipboard-screenshot
description: Pull the image sitting on the user's clipboard into the conversation so you can actually look at it. A local bridge exposes the clipboard as a per-user Unix socket ($HOME/.clipboard.sock; CLIPBOARD_SOCKET overrides); this skill retrieves the bytes, saves them as a real image file, and reads that file into context. Use it whenever the user points at something visual you cannot see — "look at my clipboard", "I just took a screenshot", "check out this error", "why does this look wrong", "here's the design", "see the paste" — including when they only imply they copied something, and including when they describe on-screen content without giving you a file path. Reach for it instead of guessing, asking them to describe the picture, or asking them to save the file somewhere first.
---

# Clipboard screenshot

The user's clipboard is invisible to you. A small bridge on this machine makes it
reachable: connect to its Unix socket and it writes the clipboard's current
contents to you and closes. When the clipboard holds a screenshot, those bytes
are a PNG (sometimes another image format).

The socket is `$HOME/.clipboard.sock` (`$CLIPBOARD_SOCKET` overrides it).
Living in the home directory is what makes several users on one machine safe:
each login's bridge — or forwarded socket, via
`RemoteForward /home/%r/.clipboard.sock <local>` in ssh config — sits in its
own home, so paths cannot collide and a grab can never read (or be fed by)
someone else's bridge. Never point `CLIPBOARD_SOCKET` at another user's
socket: that is their clipboard, not the user's.

That gives you a path from "the user copied a picture" to "you are looking at the
picture" — the missing step is that image bytes only enter your context by way of
a file you `Read`, so the bytes have to land on disk first, under a name whose
extension matches what they actually are.

## Grab it

Run the bundled script. Pass your scratchpad directory if you have one, so the
grabs stay out of the user's project:

```bash
~/.claude/skills/clipboard-screenshot/scripts/grab-clipboard-image.sh <scratchpad-dir>
```

(If this skill lives somewhere else, the script sits at `scripts/grab-clipboard-image.sh`
relative to this file.)

It prints the saved path and the detected type:

```
path: /path/to/scratchpad/clipboard-20260821-072411-317849213.png
type: PNG image data, 670 x 586, 8-bit/color RGBA, non-interlaced
```

Then `Read` that path. The image renders into the conversation and you can see it.

The script exists so this is one call instead of four, and because two details are
easy to get wrong by hand: `nc` needs its stdin redirected from `/dev/null` or it
sits holding the connection open, and the file needs the extension for its real
format — an image saved as `.png` when it is really a JPEG may not render.

## Say what you see, then carry on

Before you act on the image, state in a sentence or two what it shows.

This is not ceremony. The user cannot see which bytes you got, and clipboards go
stale — they may have copied something else since, or the screenshot they meant to
take may have captured the wrong window. If you announce "this is a terminal
showing a failing `bb golden` run" and that is not what they meant to send, they
catch it immediately, before you have spent the turn debugging the wrong thing.
A wrong grab that goes unmentioned costs far more than a sentence.

After that, get on with whatever they actually asked. The grab is usually a means
to an end — the real request is "why is this failing", "fix this layout",
"transcribe this table". If there was no other request, describing the image *is*
the answer, and you can go into more detail.

Read the image rather than working from the user's description of it. They may say
"there's an error in the logs" when the screenshot also shows the command that
produced it, the working directory, and the line number — details they did not
think to mention and that make the difference.

## When the grab fails

The script separates the failure modes because they call for different responses:

| Exit | Meaning | What to do |
|---|---|---|
| 3 | Nothing to talk to — either no socket file, or a stale one with nothing listening | The user's clipboard bridge is not running (over ssh, their remote forward is down or its socket went stale). Say so and ask the user to start it or reconnect, or to save the image to a file and give you the path. Do not retry, and do not ask them to re-copy — the bridge being down has nothing to do with what is on the clipboard. |
| 4 | Connected, but the clipboard sent nothing | The clipboard really is empty. Ask the user to copy the screenshot again; a copy that looked successful sometimes is not. |
| 5 | Clipboard holds something else | Report the type it found. If it turns out to be text the user meant to paste, they can paste it into the chat directly. |
| 6 | Connected, then the bridge never finished sending | The bridge is wedged rather than absent. Worth one retry; if it times out again the user needs to restart it. |

Exit 3 and exit 4 are worth keeping straight. A bridge that dies leaves its socket
file sitting on disk, so the file existing proves nothing — and telling someone
their clipboard is empty when really the bridge is gone sends them off re-copying
a screenshot that was there all along.

Report what happened plainly and let the user unstick it. Guessing at the contents
of an image you failed to load is worse than saying you could not load it.

## Grabbing again

Each grab is timestamped, so a second one never overwrites the first. When the user
copies something new and says "now look at this one", run the script again — reusing
the previous file would show you a stale image while they believe you are looking at
the current one. If you need to compare two screenshots, grab them one at a time and
keep both paths.
