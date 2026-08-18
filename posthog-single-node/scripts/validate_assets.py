#!/usr/bin/env python3
"""Validate a single-node PostHog configuration before it reaches a host.

Run this against your own rendered files, not just the bundled assets. Every
check here corresponds to a failure that is silent on the server: an invalid
config file makes ClickHouse start *without* the settings it describes, a
missing named collection surfaces ~267 tables into a migration, and a loopback
replica host is only visible when another container tries to dial it.

    python3 scripts/validate_assets.py <dir> [<dir> ...]

Directories are searched recursively for *.xml and compose files. Exit status is
0 when everything passes, 1 otherwise; every problem is reported, not just the
first.
"""
import sys
import pathlib
import xml.etree.ElementTree as ET

try:
    import yaml
except ImportError:
    yaml = None

EXPECTED_COLLECTIONS = {
    "msk_cluster", "warpstream_ingestion", "warpstream_calculated_events",
    "warpstream_replay", "warpstream_shared", "warpstream_cyclotron",
    "warpstream_logs", "warpstream_traces",
}
REQUIRED_MACROS = {"shard", "replica", "hostClusterType", "hostClusterRole"}
REQUIRED_SERVICES = {
    "db", "redis", "kafka", "clickhouse", "temporal",
    "capture", "plugins", "web", "worker", "caddy",
}

problems = []
notes = []


def problem(path, msg):
    problems.append(f"{path}: {msg}")


def note(path, msg):
    notes.append(f"{path}: {msg}")


def check_xml(path):
    """Parse, then check whatever this file happens to declare.

    The '--' case is worth its own message: it is legal prose in most formats
    and illegal inside an XML comment, so it is easy to introduce while editing
    the explanatory comments these files carry.
    """
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        hint = ""
        text = path.read_text(errors="ignore")
        if "--" in text:
            hint = ("  (a '--' appears in the file; that sequence is illegal "
                    "inside an XML comment - use a single hyphen)")
        problem(path, f"does not parse: {e}{hint}")
        return

    collections = root.find("named_collections")
    if collections is not None:
        names = {c.tag for c in collections}
        missing = EXPECTED_COLLECTIONS - names
        if missing:
            problem(path, "missing Kafka named collections: "
                          + ", ".join(sorted(missing)))
        for c in collections:
            broker = c.findtext("kafka_broker_list", "")
            if broker.startswith(("127.0.0.1", "localhost")):
                problem(path, f"{c.tag} points the broker at loopback "
                              f"({broker}); use the compose service name")

    macros = root.find("macros")
    if macros is not None:
        found = {m.tag for m in macros}
        missing = REQUIRED_MACROS - found
        if missing:
            problem(path, "missing macros: " + ", ".join(sorted(missing)))
        for tag, expected in (("hostClusterType", "online"),
                              ("hostClusterRole", "data")):
            actual = macros.findtext(tag)
            if actual is not None and actual != expected:
                note(path, f"{tag} is {actual!r}, not {expected!r} - PostHog's "
                           "host filter may not select this node")

    servers = root.find("remote_servers")
    if servers is not None:
        for cluster in servers:
            for replica in cluster.iter("replica"):
                host = replica.findtext("host", "")
                if host in ("127.0.0.1", "localhost"):
                    problem(path, f"cluster {cluster.tag} advertises {host}; "
                                  "other containers dial their own loopback - "
                                  "use the compose service name")

    if root.find("keeper_server") is not None and root.find("zookeeper") is None:
        problem(path, "declares keeper_server but no <zookeeper> stanza, so "
                      "ReplicatedMergeTree tables cannot find coordination")


def check_compose(path):
    if yaml is None:
        note(path, "skipped - PyYAML is not installed")
        return
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        problem(path, f"does not parse: {e}")
        return
    if not isinstance(doc, dict) or "services" not in doc:
        return
    services = doc["services"]
    missing = REQUIRED_SERVICES - set(services)
    if missing:
        problem(path, "missing services that this stack cannot run without: "
                      + ", ".join(sorted(missing)))

    def image_of(name):
        return str(services.get(name, {}).get("image", ""))

    def templated(image):
        # These assets ship as templates. An unrendered placeholder carries no
        # version information, so pin checks below would only produce noise -
        # run this again against the rendered output to get them.
        return any(m in image for m in ("<{", "{{", "${"))

    app, plugins = image_of("web"), image_of("plugins")
    if app and plugins and not (templated(app) or templated(plugins)):
        app_tag = app.rsplit(":", 1)[-1]
        plugin_tag = plugins.rsplit(":", 1)[-1]
        if app_tag != plugin_tag:
            problem(path, f"web is {app_tag} and plugins is {plugin_tag}; they "
                          "share a Postgres schema and must be one commit")
    template_count = 0
    for name, svc in services.items():
        image = str(svc.get("image", ""))
        if templated(image):
            template_count += 1
            continue
        if image.endswith((":latest", ":master")) or (
                image and ":" not in image.rsplit("/", 1)[-1]):
            note(path, f"{name} uses a floating tag ({image or 'no tag'}); "
                       "it can move under the deployment")
    if template_count:
        note(path, f"{template_count} image(s) are unrendered placeholders; "
                   "pin checks skipped - re-run against the rendered file")
    env = services.get("plugins", {}).get("environment", {})
    if isinstance(env, dict) and env and "PLUGIN_SERVER_MODE" not in env:
        note(path, "plugins has no PLUGIN_SERVER_MODE; with no mode the "
                   "process starts, finds no capabilities and exits zero")


def main(argv):
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path(".")]
    seen = 0
    for root in roots:
        if not root.exists():
            problem(root, "does not exist")
            continue
        paths = [root] if root.is_file() else sorted(root.rglob("*"))
        for p in paths:
            if p.suffix == ".xml":
                seen += 1
                check_xml(p)
            elif p.suffix in (".yml", ".yaml") and "compose" in p.name.lower():
                seen += 1
                check_compose(p)

    for n in notes:
        print(f"note:    {n}")
    for p in problems:
        print(f"PROBLEM: {p}")
    print(f"\n{seen} file(s) checked, {len(problems)} problem(s), "
          f"{len(notes)} note(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
