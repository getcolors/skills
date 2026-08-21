#!/usr/bin/env python3
"""Validate a single-node Rybbit configuration before it reaches a host.

Run this against your own rendered files, not only the bundled templates. Every
check corresponds to a failure that is silent on the server: a floating tag
moves under the deployment with no record of what changed, a datastore with a
published port is on the internet, a Caddyfile without trusted_proxies logs the
CDN instead of the visitor, and a ClickHouse profile without the JSON types
means the schema never builds.

    python3 scripts/validate_assets.py <dir> [<dir> ...]

Directories are searched recursively. Exit status is 0 when everything passes,
1 otherwise; every problem is reported, not just the first. PROBLEM lines are
failures, notes are advisory.

Ansible/Jinja placeholders are tolerated, so this runs against templates too --
checks that need a concrete value are skipped and counted rather than guessed.
"""
import re
import sys
import pathlib
import xml.etree.ElementTree as ET

try:
    import yaml
except ImportError:
    yaml = None

REQUIRED_SERVICES = {"caddy", "postgres", "clickhouse", "redis", "backend", "client"}

# Everything except the proxy must stay on the private network. A published port
# on a datastore makes the provider firewall the only thing in front of it.
MUST_NOT_PUBLISH = {"postgres", "clickhouse", "redis", "backend", "client"}

# These two are halves of one application sharing a Postgres schema, and both
# publish a moving :latest. A digest is the only pin that cannot move.
APPLICATION_SERVICES = ("backend", "client")

TEMPLATE = re.compile(r"\{\{.*?\}\}|\{%.*?%\}|<\{.*?\}>")

problems: list[str] = []
notes: list[str] = []


def problem(path, msg):
    problems.append(f"{path}: {msg}")


def note(path, msg):
    notes.append(f"{path}: {msg}")


def detemplate(text):
    """Replace Jinja/scaffold placeholders with an inert token.

    Left alone, '{{ x }}' is legal YAML -- a flow mapping -- so the file parses
    into something subtly wrong rather than failing. Substituting first means a
    template and its rendered output take the same path through these checks.
    """
    return TEMPLATE.sub("TEMPLATED", text)


def is_templated(value):
    return "TEMPLATED" in str(value)


def floating(image):
    """A tag that can move under the deployment."""
    if "@sha256:" in image:
        return False
    last = image.rsplit("/", 1)[-1]
    if ":" not in last:
        return True
    return last.rsplit(":", 1)[-1] in ("latest", "master", "main", "edge")


def check_compose(path, text):
    if yaml is None:
        note(path, "skipped - PyYAML is not installed")
        return
    try:
        doc = yaml.safe_load(detemplate(text))
    except yaml.YAMLError as e:
        problem(path, f"does not parse: {e}")
        return
    if not isinstance(doc, dict) or "services" not in doc:
        return
    services = doc["services"] or {}

    missing = REQUIRED_SERVICES - set(services)
    if missing:
        problem(path, "missing services this stack cannot run without: "
                      + ", ".join(sorted(missing)))

    for name in sorted(MUST_NOT_PUBLISH & set(services)):
        if services[name].get("ports"):
            problem(path, f"{name} publishes a port; datastores and application "
                          "ports belong on the private network, with only the "
                          "proxy exposed")

    templated = 0
    for name, svc in sorted(services.items()):
        image = str((svc or {}).get("image", ""))
        if not image:
            continue
        if is_templated(image):
            templated += 1
            continue
        if floating(image):
            if name in APPLICATION_SERVICES:
                problem(path, f"{name} uses a floating tag ({image}); pin the "
                              "application images by digest - a converge can "
                              "otherwise deploy something different with no "
                              "change on your side")
            else:
                note(path, f"{name} uses a floating tag ({image}); pin it for "
                           "reproducibility")

    pinned = {n: str(services.get(n, {}).get("image", "")) for n in APPLICATION_SERVICES}
    concrete = {n: v for n, v in pinned.items() if v and not is_templated(v)}
    if len(concrete) == 2:
        by_digest = ["@sha256:" in v for v in concrete.values()]
        if any(by_digest) and not all(by_digest):
            problem(path, "backend and client are pinned differently; they share "
                          "a Postgres schema and must move together, so pin both "
                          "by digest")

    redis = services.get("redis", {}) or {}
    command = str(redis.get("command", ""))
    if command and not is_templated(command):
        if "noeviction" not in command:
            problem(path, "redis does not set --maxmemory-policy noeviction; it "
                          "carries queue and session state, not cache, and an "
                          "eviction policy silently discards work")
        if "appendonly yes" not in command:
            note(path, "redis has no --appendonly yes; queue state will not "
                       "survive a restart")

    clickhouse = services.get("clickhouse", {}) or {}
    mounts = " ".join(str(v) for v in (clickhouse.get("volumes") or []))
    if "users.d" not in mounts:
        problem(path, "clickhouse mounts no users.d profile; Rybbit's schema "
                      "needs the experimental JSON and object types, which are "
                      "off by default")

    caddy = services.get("caddy", {}) or {}
    if caddy and not (caddy.get("logging") or {}):
        note(path, "caddy has no logging options; the json-file driver does not "
                   "rotate and access logging is one line per request")

    if templated:
        note(path, f"{templated} image(s) are unrendered placeholders; pin "
                   "checks skipped - re-run against the rendered file")


def check_caddyfile(path, text):
    body = detemplate(text)
    if "trusted_proxies" not in body:
        note(path, "no trusted_proxies. Correct if nothing proxies the origin; "
                   "behind a CDN, Caddy attributes every request to the edge and "
                   "the access log becomes useless for the one question it is "
                   "read for")
    if "log {" not in body and "log{" not in body:
        problem(path, "no access log block; Caddy logs nothing for a successful "
                      "request by default, which leaves an ingestion endpoint "
                      "with no evidence that anything ever arrived")
    if "reverse_proxy" not in body:
        problem(path, "no reverse_proxy directive")
    elif "/api/" not in body:
        problem(path, "no /api/* route; ingestion and the API share that prefix "
                      "and must reach the backend, not the client")


def check_backup(path, text):
    body = detemplate(text)
    if "BACKUP DATABASE" not in body:
        problem(path, "does not use ClickHouse's BACKUP statement; taring a live "
                      "data directory races the server's merges and produces an "
                      "archive that cannot be restored")
    if re.search(r"\|\|\s*(tar|.*tar )", body):
        problem(path, "has a fallback path around the ClickHouse backup; an "
                      "unrestorable archive is worse than a failed unit")
    if "information_schema.tables" not in body:
        problem(path, "never verifies the dump restores; load it into a scratch "
                      "database and require the schema back before uploading")
    if "rclone delete" not in body and "--min-age" not in body:
        problem(path, "prunes no remote objects; retention that applies only to "
                      "the local disk is not a retention policy")
    if "set -euo pipefail" not in body:
        note(path, "does not set -euo pipefail; a failing stage should fail the "
                   "unit rather than uploading whatever it produced")


def uncommented(text):
    """Drop YAML comments.

    These files explain their reasoning inline, and several of them name the
    very setting a check forbids in order to say why it is absent. Matching the
    prose would report the explanation as the defect.
    """
    return "\n".join(re.sub(r"(?<!\S)#.*$", "", line) for line in text.splitlines())


def check_playbook(path, text):
    body = detemplate(uncommented(text))

    if re.search(r"^\s*cache_valid_time\s*:", body, re.M):
        problem(path, "sets cache_valid_time on apt; a fresh cloud image ships "
                      "package lists naming superseded versions, and the install "
                      "then fails on a 404")

    # Only a playbook that installs the stack owes the delivery guarantees; a
    # teardown playbook legitimately does neither.
    if "docker compose up" not in body:
        return

    if "force-recreate" not in body:
        note(path, "never force-recreates a service. A single-file bind mount "
                   "keeps its inode across a copy, and env_file is read at "
                   "container creation - both need an explicit recreate")
    if "sha256sum" not in body and "checksum" not in body:
        note(path, "does not compare a running container's config against the "
                   "file on disk; Ansible change flags cannot see the inode trap")
    if "update_cache" not in body:
        note(path, "does not refresh apt lists before installing")


def check_xml(path, text):
    try:
        root = ET.fromstring(detemplate(text))
    except ET.ParseError as e:
        hint = ""
        if "--" in text:
            hint = ("  (a '--' appears in the file; that sequence is illegal "
                    "inside an XML comment - use a single hyphen)")
        problem(path, f"does not parse: {e}{hint}")
        return
    body = ET.tostring(root, encoding="unicode")
    if "allow_experimental" in body and "allow_experimental_json_type" not in body:
        note(path, "enables some experimental types but not "
                   "allow_experimental_json_type, which Rybbit's schema needs")


def main(argv):
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path(".")]
    seen = 0
    for root in roots:
        if not root.exists():
            problem(root, "does not exist")
            continue
        paths = [root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file())
        for p in paths:
            name = p.name.lower()
            try:
                text = p.read_text(errors="ignore")
            except OSError as e:
                problem(p, f"cannot be read: {e}")
                continue
            if p.suffix in (".yml", ".yaml") and "compose" in name:
                seen += 1
                check_compose(p, text)
            elif p.suffix in (".yml", ".yaml") and ("hosts:" in text or "tasks:" in text):
                seen += 1
                check_playbook(p, text)
            elif name.startswith("caddyfile"):
                seen += 1
                check_caddyfile(p, text)
            elif name in ("backup", "backup.sh"):
                seen += 1
                check_backup(p, text)
            elif p.suffix == ".xml":
                seen += 1
                check_xml(p, text)

    for n in notes:
        print(f"note:    {n}")
    for p in problems:
        print(f"PROBLEM: {p}")
    print(f"\n{seen} file(s) checked, {len(problems)} problem(s), "
          f"{len(notes)} note(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
