# Failure catalogue

Symptom-indexed. Every error string below was produced by a real converge of
this stack on 2026-09-01; search this file for the text on your screen.

Companion package: `github.com/getcolors/automq` (green). The fixes are in its
templates — this file explains what the symptom meant and why the fix is what
it is. It carries no copies of that package's files.

---

## 1. `error creating VPC 2.0: {"error":"Not found.","status":404}`

```
Error: error creating VPC 2.0: {"error":"Not found.","status":404}

  with vultr_vpc2.cluster,
  on main.tf line 34, in resource "vultr_vpc2" "cluster":
```

**Means:** Vultr has retired the VPC 2.0 API. Not a permissions problem, not a
provider bug, and not something reading the provider will tell you — the
Terraform provider still ships the `vultr_vpc2` resource *and* its docs. Its
own deprecation warning appears only once you already have such a resource in
state:

```
VPC2 is deprecated and will not be supported in a future release. Use VPC instead
```

**Proof, in two calls:**

```sh
curl -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY" https://api.vultr.com/v2/vpc2   # 404
curl -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY" https://api.vultr.com/v2/vpcs   # 200
```

**Fix:** `vultr_vpc` (`v4_subnet` + `v4_subnet_mask`), attached with `vpc_ids`
on the instance. `internal_ip` is still the exported private address.

**Generalises to:** provider source is evidence about the *client*, never about
the endpoint. Probe the live API before trusting a resource that compiles.

---

## 2. `Port numbers must be between 1 and 65535` on a port you did set

```
Error: error creating firewall rule : {"error":"Port numbers must be between 1 and 65535","status":400}
  with vultr_firewall_rule.kafka["0.0.0.0/0"],
```

**Means:** the rendered value was empty — `port = ""`. A template key the
renderer does not have produces an empty string rather than an error, so it
passes `build`, `golden`, `--dry-run` and `validate` alike and is rejected only
by the provider on a real apply. The neighbouring SSH rule hard-coded `"22"`
and was unaffected, which is why nothing caught it earlier.

**Fix:** supply the key, and add a gate that fails on `= ""` in any rendered
`.tf`. Catch the class, not the instance.

---

## 3. Every SASL principal fails, including ones you never changed

```
org.apache.kafka.common.errors.SaslAuthenticationException: Authentication
failed during authentication due to invalid credentials with SASL mechanism
SCRAM-SHA-512
```

**This is the most expensive failure in this catalogue. Read all of it before
touching credentials.**

What it is *not*:

- **Not credential drift.** `sha256sum /etc/automq/secrets/secrets.env` was
  identical on all three nodes.
- **Not a wrong salted-password derivation.** Verified by formatting two
  scratch directories, one with `salt=…,saltedpassword=…` and one with
  `salt=…,password=…`, then decoding both:
  ```sh
  kafka-storage.sh format --cluster-id <id> --config <cfg> \
      --add-scram 'SCRAM-SHA-512=[name=probe,salt=…,saltedpassword=…,iterations=8192]'
  kafka-dump-log.sh --cluster-metadata-decoder --files <dir>/bootstrap.checkpoint
  ```
  Both produced byte-identical `storedKey` and `serverKey`. PBKDF2-HMAC-SHA512
  over the plaintext with that salt and iteration count is exactly what Kafka
  computes; the explicit form is correct.

What it **was**: the live `bootstrap.checkpoint` contained no
`USER_SCRAM_CREDENTIAL_RECORD` at all.

```sh
kafka-dump-log.sh --cluster-metadata-decoder \
  --files /var/lib/automq/metadata/bootstrap.checkpoint | grep -c USER_SCRAM_CREDENTIAL_RECORD
# 0  → the cluster can never authenticate anyone
# 3  → healthy (admin, broker, client)
```

**Root cause:** an earlier converge *claimed* a genesis marker and then failed
during the format. Every later run asked "has genesis been claimed?", got yes,
and formatted its nodes **without** `--add-scram`. The cluster was permanently
unable to hold a credential, and re-running could never repair it.

**There is no in-place recovery.** The one path you would reach for is closed:

```
org.apache.kafka.common.errors.UnsupportedEndpointTypeException: This Admin API
is not yet supported when communicating directly with the controller quorum.
```

so `kafka-configs --bootstrap-controller` cannot add the missing user either.
Recovery is: wipe `/var/lib/automq/metadata` on every node, delete the per-node
format records and the genesis marker from the ops bucket, and converge again
as a true genesis.

**The rule that prevents it:** a marker may record that something happened;
only *evidence* that it happened may decide what to do next. Derive "has this
cluster been initialized?" from whether any node has a **format-complete**
record — never from a marker written before the work.

---

## 4. Quorum never elects; the broker dies 60s later blaming itself

Four symptoms, in the order you will meet them. Only the last is the cause.

```
java.lang.RuntimeException: Received a fatal error while waiting for the
controller to acknowledge that we are caught up
  at kafka.server.BrokerServer.startup(BrokerServer.scala:591)
Caused by: java.util.concurrent.CancellationException
```
```
[MetadataLoader id=0] initializeNewPublishers: the loader is still catching up
because we still don't know the high water mark yet.
```
```
[RaftManager id=0] Election has timed out, backing off for 1000ms before
becoming a candidate again
[RaftManager id=0] Completed transition to CandidateState(... epoch=53 ...)
```

Every node a perpetual candidate, epoch climbing forever, no votes exchanged.
Nothing mentions networking.

**What is simultaneously true:** all three nodes ARE listening
(`LISTEN [::ffff:10.40.0.3]:9093`), the quorum string IS correct and matches
the real private addresses, and **ping between the nodes succeeds**.

**Means:** TCP between the nodes is being dropped while ICMP passes. There are
**two** firewalls in front of a Vultr node and both must be opened:

1. the **Vultr firewall group**, which filters the private interface too — add
   rules for the controller and inter-broker ports scoped to the VPC subnet;
2. **ufw on the host**, which the Vultr Ubuntu image ships **enabled**:
   ```
   Status: active
   Default: deny (incoming), allow (outgoing), deny (routed)
   22/tcp                     ALLOW IN    Anywhere
   ```
   That single rule is the whole allowlist. It would also have silently blocked
   the public Kafka port.

**Diagnostic order that actually works — ping is not a TCP test:**

```sh
ping -c1 10.40.0.5                      # passes even when every TCP port is dead
python3 -c 'import socket; socket.create_connection(("10.40.0.5",9999),5)'   # the real test
ufw status                              # check the HOST first
# then the provider's firewall group
```

---

## 5. `Could not find a 'KafkaServer' or 'external.KafkaServer' entry`

```
java.lang.IllegalArgumentException: Could not find a 'KafkaServer' or
'external.KafkaServer' entry in the JAAS configuration. System property
'java.security.auth.login.config' is not set
```
followed by a crash loop (19 restarts observed) and, as a *consequence*, the
"still catching up … high water mark" line from entry 4.

**Means:** the public `SASL_SSL`/SCRAM listener has no listener-scoped JAAS
entry. Easy to omit precisely because it carries **no credentials** — a SCRAM
*server* validates against the metadata log, so it needs a login context and
nothing else. The message names a *file* (`java.security.auth.login.config`)
when what is missing is a *property*:

```properties
listener.name.external.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;
```

The controller listener reporting `authorizerStart completed for endpoint
CONTROLLER. Endpoint is now READY` just before the crash is direct evidence
that SASL/PLAIN on the controller listener works.

---

## 6. `java.nio.file.NoSuchFileException` on a file you can `cat`

```
Exception in thread "main" java.nio.file.NoSuchFileException: /etc/automq/server.properties
    at kafka.tools.StorageTool$.execute(StorageTool.scala:79)
```
and its sibling:
```
Properties file /etc/automq/admin.properties does not exists!
```

**Means:** a host path was handed to a tool running **inside** the container.
Both are true statements about different namespaces. `kafka-storage.sh` and
every `kafka-*.sh` the gates and operator commands invoke run in the container,
so they need the container's path — and any properties file they read must be
bind-mounted, not merely present on the host.

**Fix:** one constant feeding both the `-v` target and the `--config`
argument, so the mount point and the argument cannot drift apart.

---

## 7. `Incorrect Usage: flag provided but not defined: -accept-tos`

```
Incorrect Usage: flag provided but not defined: -accept-tos
VERSION: 5.4.0
GLOBAL OPTIONS: --help, --version, --log.format, --log.level, --config
```

**Means:** lego 5.x moved `--accept-tos`, `--email`, `--domains` and `--path`
out of the global options and under the subcommand. Every pre-5.x example puts
them before `run`, and they all fail this way.

**Correct form:**

```sh
export LEGO_PATH=/etc/automq/lego
lego run -a -m "$EMAIL" -d name1 -d name2 \
    --dns cloudflare --dns.resolvers 1.1.1.1:53 --dns.propagation.disable-rns
lego renew -m "$EMAIL" -d name1 -d name2 --dns cloudflare …
```

`--dns.propagation.disable-rns` matters: lego otherwise polls the zone's
authoritative nameservers and waits for unanimity, which Cloudflare's anycast
estate does not provide the way it expects.

---

## 8. `Unknown parameter in input: "IfNoneMatch"`

```
botocore.exceptions.ParamValidationError: Parameter validation failed:
Unknown parameter in input: "IfNoneMatch", must be one of: ACL, Body, Bucket, …
```

**Means:** this never reached the network. The distribution's
`python3-boto3`/botocore predates boto3's `IfNoneMatch` parameter on
`put_object` and rejects it client-side. **The wire protocol is older than the
SDK's support for it.**

**Fix without adding a pip/venv dependency to the host** — send the header
directly:

```python
def handler(request, **_):
    request.headers.add_header("If-None-Match", "*")
s3.meta.events.register("before-sign.s3.PutObject", handler)
try:
    s3.put_object(**args)          # 412 → the object already existed
finally:
    s3.meta.events.unregister("before-sign.s3.PutObject", handler)
```

**Verified against real Cloudflare R2**, two competing holders:

```
{"acquired": true,  "holder": "probe-1"}
{"acquired": false, "holder": "probe-1"}   ← probe-2 refused
```

R2 does honour `If-None-Match: *`, so conditional-create ownership works.

---

## 9. `Syntax error in template: unexpected char '…'`

```
Syntax error in template: unexpected char '…' at 308
Origin: .../automq-ansible/server.properties:7
7 #   {{ … }}   per-node facts from the inventory — node id, listeners, names
```

**Means:** the file's own header comment explained its delimiters by *showing*
them. Selmer silently consumed its example and Jinja rejected the other as a
syntax error. **There is no comment syntax in a templating pass** — a literal
example of a delimiter is not a comment to the engine that owns it. Describe
delimiters in words.

---

## 10. The package refuses to converge because of its own ssh block

```
refusing to manage /home/ubuntu/.ssh/config: it already declares
`Host automq-vultr-0` at line 8 outside this package's managed block.
```

**Means:** the block was not foreign — this deployment wrote it. A multi-node
deployment writes **one** managed block, marked with the profile, containing a
`Host` stanza for the profile and one per node. If the ownership check derives
the marker from the stanza it is searching for, it looks for
`# BEGIN automq-vultr-0 …`, never finds it, and concludes the stanza sits
outside any managed block.

Invisible with one machine, where the marker alias and the stanza alias are the
same string.

---

## 11. `... that is not in this deployment's state ...` for a key you just made

```
vultr already has an SSH key named automq-vultr (id 7692e92a-…) that is not in
this deployment's state and matches ~/.ssh/automq-vultr.pub: a previous delete
left it behind.
```

**Means:** ownership is read from the compute stage's `params.ssh_key_id`
output. A multi-node stack naturally emits `params` as a *list* of nodes, which
has nowhere to put a key id — so ownership is unresolvable and a key created
ninety seconds earlier is reported as somebody else's.

**Fix:** `params` is an object — `{ ssh_key_id, nodes: [...] }`. When
normalizing HCL snake_case to kebab-case, hyphenate **only** the node entries;
`ssh_key_id` must survive verbatim or the same failure returns one layer in.

Related, and benign: after a compute failure the first retry stops with
*"exists but no compute state is readable"*. That is the create matrix working.
Confirm no host survives, then follow the message.

---

## 12. Gates that pass exactly once

```
FAIL — produced 500 records, consumed a different set
  ok   — 3 brokers registered
  ok   — controller quorum: 3 voters, leader 0
```

**Means:** the cluster is fine. The gate created its topic `--if-not-exists`,
produced N records, consumed N from the beginning and diffed — so on the second
converge it consumed the *previous* run's records.

The same flaw hid in two more gates: one asserted exactly 100 pre-failure
records survived (200 on the second run), and one reused a consumer group whose
committed offsets pointed at a topic since recreated.

**Fix:** recreate the gate's topic (waiting out Kafka's asynchronous deletion
before reusing the name), and tag every record and group with a per-run value
so each gate counts what *this* run produced.

**Generalises to:** idempotency applies to the gates, not just the converge. A
gate that only passes on a fresh cluster is a first-run demonstration — and the
first run is the one you watch.

---

## 13. `kcat -G` silently consumes nothing

A consumer-group gate failed with "no committed offsets" against a cluster that
commits offsets normally.

**Means:** `kcat -G <group> <topic>` takes the topic **positionally** and
**replaces** `-C`. Written as `kcat -C -t <topic> -G <group>` it consumes
nothing and commits nothing, so any later assertion about the group is doomed
regardless of the cluster.


---

## 14. Rebuilding node 0 quietly replaces the cluster's credentials

No error text — that is the point. If the node that generated the cluster's
secret bundle is rebuilt while the cluster and its object storage survive, a
create-once-*per-host* generator sees no bundle locally, mints a fresh one, and
distributes new passwords and SCRAM salts to the surviving nodes. The
credentials in the metadata log do not change, so the cluster now disagrees
with itself and you are back at entry 3 with no repair path.

**Rule:** the bundle is a property of the *cluster*, not of a host. Source it
from whichever node still has it, and refuse to generate one whenever any node
carries a format-complete record.

---

## 15. Configuration changes that converge successfully and do nothing

Also no error text. `docker compose up -d` does **not** recreate a container
because the *contents* of a bind-mounted file changed — Compose compares its
own service definition, not the bytes behind the mount. So an edit to
listeners, ACLs, storage, heap or retention renders correctly, reports a
changed task, reports a successful converge, and the JVM keeps running the
configuration it started with.

**Fix:** detect that the rendered configuration actually changed and restart
the broker — one node at a time on a combined broker+controller cluster, with a
health wait between.

---

## 16. Two nodes holding the same restart lease

A lease whose TTL has expired must not be replaced with an unconditional write:
two contenders both read the expired object, both overwrite it, and both report
success. On combined broker+controller nodes that is a simultaneous restart and
a lost majority.

Acquire conditionally in both directions — a conditional create when the lease
is absent, a conditional replace against the exact ETag that was read when it
is expired — and scope release to the holder, or a node whose lease expired
while it was still restarting will delete its successor's lease on the way out.


---

## 17. A gate reporting data loss that did not happen

```
FAIL — only 0 of 100 pre-failure records survived
```

The most alarming line this deployment can print, and on the run that produced
it nothing had been lost. Checked immediately, independently:

```
colors-failover:0:101      <- 100 "before-" records plus the one written during
colors-failover:1..5:0        the outage, all present
```

**Means:** the gate read the victim partition **once**, right after its leader
was killed, while the partition was still being reassigned. The fetch failed,
stderr was suppressed, `grep -c` counted zero, and transient unavailability was
reported as permanent loss.

**Fix:** retry the survival read (keeping the highest count seen) and verify
the pre-kill produce actually succeeded — an unverified produce makes the same
gate claim data loss for records that were never written.

**The rule:** a gate asserting a catastrophic outcome needs *more* evidence
than one asserting success, not less. "Not readable yet" and "gone" are
indistinguishable from a single read at the wrong moment, and only one of them
is an emergency.

Related, ruled out by experiment during the same investigation: `kcat -p N`
does correctly target partition N on produce. A probe record sent with `-p 4`
landed in partition 4 and not in 0, so a producer ignoring the flag was not the
explanation.
