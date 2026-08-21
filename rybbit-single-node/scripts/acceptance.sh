#!/usr/bin/env bash
# Verify a converged single-node Rybbit deployment.
#
# The governing rule: every claim this reports is one it actually checked. A 2xx
# from /api/track, a healthy container and a successful `systemctl start` of the
# backup unit are all compatible with a deployment that stores nothing and has
# no recoverable data. See references/acceptance.md.
#
# Derived from an implementation verified against a live deployment; this shell
# port has not itself been run end to end, so read it before trusting it.
#
#   HOST=rybbit.example.com IP=203.0.113.10 \
#   BACKUP_BUCKET=rybbit-backup BACKUP_ENDPOINT=https://... \
#   ./acceptance.sh
#
# The backup check reads the credentials the backup unit itself uses, from the
# EnvironmentFile on the host. The defaults match the bundled Ansible; a stack
# converged by something else may write the same file with different variable
# names (the getcolors rybbit package uses RYBBIT_BACKUP_R2_ACCESS_KEY_ID /
# RYBBIT_BACKUP_R2_SECRET_ACCESS_KEY), so the file path and both names are
# overridable:
#
#   BACKUP_ENV_FILE=/etc/rybbit-backup.env \
#   BACKUP_KEY_ID_VAR=BACKUP_ACCESS_KEY_ID \
#   BACKUP_SECRET_VAR=BACKUP_SECRET_ACCESS_KEY
#
# Getting them wrong fails the right way -- an empty listing and a FAILED
# verdict -- but against a deployment whose backups are actually fine.
#
# Exit 0 only if every check passed.

set -uo pipefail

HOST=${HOST:?set HOST to the public hostname}
IP=${IP:?set IP to the machine address}
SSH_USER=${SSH_USER:-root}
ACCEPTANCE_DOMAIN=${ACCEPTANCE_DOMAIN:-colors-acceptance.invalid}
BACKUP_BUCKET=${BACKUP_BUCKET:-}
BACKUP_ENDPOINT=${BACKUP_ENDPOINT:-}
BACKUP_PREFIX=${BACKUP_PREFIX:-rybbit}
BACKUP_ENV_FILE=${BACKUP_ENV_FILE:-/etc/rybbit-backup.env}
BACKUP_KEY_ID_VAR=${BACKUP_KEY_ID_VAR:-BACKUP_ACCESS_KEY_ID}
BACKUP_SECRET_VAR=${BACKUP_SECRET_VAR:-BACKUP_SECRET_ACCESS_KEY}
HEALTH_ATTEMPTS=${HEALTH_ATTEMPTS:-60}
INGEST_ATTEMPTS=${INGEST_ATTEMPTS:-10}

base="https://$HOST"
failed=0

pass() { printf '  ok       %s\n' "$1"; }
fail() { printf '  FAILED   %s\n' "$1"; failed=1; }
skip() { printf '  skipped  %s\n' "$1"; }

remote() {
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$IP" "$1" 2>/dev/null
}

# Load the generated stack.env on the host, then run a command with it in scope.
stack() { remote "cd /opt/rybbit && set -a && . ./stack.env && set +a && $1"; }

psql_q() {
  stack "docker compose exec -T postgres psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc '$1'"
}

# Resolve the events table from system.tables rather than hardcoding a database
# name Rybbit's migrations own, then run the query against it as $t.
ch_q() {
  stack "t=\$(docker compose exec -T clickhouse clickhouse-client \
      --user \"\$CLICKHOUSE_USER\" --password \"\$CLICKHOUSE_PASSWORD\" \
      --query \"SELECT database || '.' || name FROM system.tables \
                WHERE name = 'events' AND database NOT IN ('system') \
                ORDER BY database LIMIT 1\" | tr -d '\r'); \
    [ -n \"\$t\" ] && docker compose exec -T clickhouse clickhouse-client \
      --user \"\$CLICKHOUSE_USER\" --password \"\$CLICKHOUSE_PASSWORD\" --query \"$1\""
}

event_count() { ch_q 'SELECT count() FROM $t' | tr -d '[:space:]'; }

echo "== TLS and health =="

# No -k, deliberately. A broken certificate is one of the few things that will
# actually stop real browsers ingesting, so accepting one defeats the check.
ok=""
for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
  if curl -fsS "$base/api/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [ -n "$ok" ]; then
  pass "https://$HOST/api/health with a verified certificate"
else
  fail "HTTPS health did not become ready with a valid certificate"
  # Separating these two tells you whether the fault is the application or the
  # path in front of it, which is otherwise a guess.
  if [ -n "$(remote 'cd /opt/rybbit && docker compose exec -T backend wget -qO- http://127.0.0.1:3001/api/health')" ]; then
    echo "           (the backend answers inside the container: look at Caddy, DNS or TLS)"
  else
    echo "           (the backend does not answer inside the container either: look at the application)"
  fi
fi

echo "== Ingestion =="

before=$(event_count)
if ! [[ "$before" =~ ^[0-9]+$ ]]; then
  fail "could not read the ClickHouse events table to verify ingestion"
else
  # A dedicated throwaway site, created on demand, so a converge never writes
  # test rows into real analytics. Literals are dollar-quoted because the query
  # travels inside single quotes in a remote shell, where an escaped quote would
  # arrive at psql verbatim.
  site=$(psql_q "insert into sites (name, domain, organization_id) \
select \$\$colors-acceptance\$\$, \$\$$ACCEPTANCE_DOMAIN\$\$, (select id from organization limit 1) \
where not exists (select 1 from sites where domain = \$\$$ACCEPTANCE_DOMAIN\$\$); \
select site_id from sites where domain = \$\$$ACCEPTANCE_DOMAIN\$\$ limit 1" \
    | tail -n 1 | tr -d '[:space:]')

  # psql prints the INSERT tag before the SELECT result, so the id comes off the
  # last line and has to look like one -- the whole output is not a site id.
  if ! [[ "$site" =~ ^[0-9]+$ ]]; then
    # Not a claim about ingestion. Nothing was tested.
    skip "not-configured: no site to track against, so no event was sent"
  else
    # Two payload details, both verified against Rybbit's own zod schema
    # (server/src/services/tracker/trackingPayload.ts):
    #
    #   - it discriminates on `type`, not `name`; anything else is answered with
    #     400 "Invalid discriminator value".
    #   - `site_id` is `z.string()`, so it must be QUOTED. Sending the bare
    #     number is rejected, and the check then reports "rejected" against a
    #     perfectly healthy stack -- a false alarm that looks like a real one.
    #
    # The User-Agent matters because sites default to blockBots true, and a UA
    # classified as a bot is answered 200 with no row stored, which is
    # indistinguishable from a broken pipeline. An earlier version masqueraded
    # as desktop Chrome, and that is exactly wrong for a synthetic check:
    # observed live on 2026-08-21, a claimed-Chrome UA arriving with none of a
    # real Chrome's client-hint headers scored header_heuristics, stacked with
    # bot_asn (checks run from datacenter addresses), and the event was
    # silently diverted. A Mozilla-prefixed string that claims no specific
    # browser trips neither the UA patterns nor the header heuristics, and one
    # ASN signal alone does not cross the threshold -- that combination was
    # stored and read back.
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
      -X POST -H 'content-type: application/json' \
      -H 'User-Agent: Mozilla/5.0 (Colors acceptance)' \
      --data "{\"type\":\"pageview\",\"site_id\":\"$site\",\"pathname\":\"/colors-acceptance\"}" \
      "$base/api/track" 2>/dev/null)

    # Ingestion is asynchronous: sampling once is a race, so poll.
    after="$before"
    for _ in $(seq 1 "$INGEST_ATTEMPTS"); do
      sleep 3
      n=$(event_count)
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$before" ]; then after="$n"; break; fi
    done

    if [ -z "$status" ]; then
      fail "unreachable: no response from /api/track (look at Caddy, DNS, TLS)"
    elif [ "$after" -gt "$before" ]; then
      pass "ingested: a synthetic event was read back out of ClickHouse"
    elif [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
      fail "dropped: /api/track returned $status and no row was stored"
      echo "           (bot blocking first -- sites default to blockBots true and a"
      echo "            bot-classified User-Agent is answered 200 with no row; then"
      echo "            backend to ClickHouse, the schema, and the JSON type setting)"
    else
      fail "rejected: /api/track returned $status (check the payload shape first, then the backend and proxy routing)"
    fi
  fi
fi

echo "== Backups =="

if [ -z "$BACKUP_BUCKET" ] || [ -z "$BACKUP_ENDPOINT" ]; then
  skip "backup check: set BACKUP_BUCKET and BACKUP_ENDPOINT to run it"
else
  # Captured before the trigger, so this tests THIS run rather than some run.
  since=$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -v-2M +%Y-%m-%dT%H:%M:%SZ)

  if [ -z "$(remote 'systemctl start rybbit-backup.service && systemctl is-active rybbit-backup.timer')" ]; then
    fail "backup unit or timer is not healthy"
  else
    rclone_env="RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
RCLONE_CONFIG_R2_REGION=auto RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
RCLONE_CONFIG_R2_ENDPOINT=$BACKUP_ENDPOINT"
    listing=$(remote "set -a; . $BACKUP_ENV_FILE; set +a; $rclone_env \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID=\"\$$BACKUP_KEY_ID_VAR\" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=\"\$$BACKUP_SECRET_VAR\" \
      rclone lsjson --files-only r2:$BACKUP_BUCKET/$BACKUP_PREFIX")

    # A non-empty object newer than the timestamp taken before the trigger.
    # Existence alone says nothing: the bucket may hold one lucky object from
    # weeks ago.
    if printf '%s' "$listing" | python3 -c '
import json, sys
from datetime import datetime, timezone
since = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
try:
    entries = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in entries:
    if e.get("Size", 0) > 0:
        t = e.get("ModTime", "").replace("Z", "+00:00")
        try:
            if datetime.fromisoformat(t) >= since:
                sys.exit(0)
        except ValueError:
            pass
sys.exit(1)
' "$since"; then
      pass "a non-empty backup object newer than this run exists in the bucket"
    else
      fail "no backup object newer than this run under $BACKUP_BUCKET/$BACKUP_PREFIX"
    fi
  fi
fi

echo "== Signup policy =="

# Ask the running application. The file on disk and the running container
# disagree until the services are recreated, and the file is the one that looks
# right.
config=$(curl -fsS "$base/api/config" 2>/dev/null)
if [ -z "$config" ]; then
  skip "could not read /api/config"
else
  case "$config" in
    *'"disableSignup":true'*)  pass "signup is disabled on the running application" ;;
    *'"disableSignup":false'*) skip "signup is OPEN on the running application - intended only until the owner account is registered" ;;
    *)                         skip "could not determine the signup policy from /api/config" ;;
  esac
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "acceptance passed"
else
  echo "acceptance FAILED"
fi
exit "$failed"
