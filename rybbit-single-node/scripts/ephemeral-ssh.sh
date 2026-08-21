#!/usr/bin/env bash
# A disposable SSH agent and key for one deployment.
#
# WHY: a converge needs a key that OpenTofu's remote-exec, Ansible, and ad-hoc
# ssh can all use. Reaching for your long-lived personal key puts it on every
# throwaway test machine and leaves it in the provider account afterwards. A
# per-deployment key that is created, used, and destroyed with the machine has
# none of that blast radius -- and a test instance you delete an hour later
# never held anything you care about.
#
# WHY AN AGENT, rather than naming the key file everywhere: OpenTofu's
# remote-exec provisioner uses a Go SSH client that ignores ~/.ssh/config and
# reads SSH_AUTH_SOCK, while Ansible uses OpenSSH, which reads the config and
# may ignore the agent. Consolidating on one agent gives both a single source
# of identity instead of parallel paths that can drift apart.
#
# THE HOST-CONFIG TRAP this exists to defeat: a ~/.ssh/config with
#
#     Host *
#       IdentityFile ~/.ssh/id_ed25519
#       IdentitiesOnly yes
#       IdentityAgent none
#
# stops OpenSSH consulting any agent at all. `IdentityAgent none` disables it,
# and `IdentitiesOnly yes` would restrict it to keys matching a configured
# IdentityFile even if it were enabled. Command-line -o options win over the
# config, so the exported ANSIBLE_SSH_ARGS sets BOTH `IdentityAgent=<sock>` and
# `IdentitiesOnly=no`. Setting only one of them silently fails to authenticate.
#
# USAGE
#   eval "$(./ephemeral-ssh.sh start)"   # create key + agent, export the env
#   ./ephemeral-ssh.sh pubkey            # print the public key (feed to OpenTofu)
#   ./ephemeral-ssh.sh status
#   ./ephemeral-ssh.sh stop              # kill the agent, delete the key
#
# The directory defaults to ./.ssh and can be overridden with EPHEMERAL_SSH_DIR
# or a second argument. Everything lives there; nothing touches ~/.ssh.
#
# Register the public key with the provider as a resource rather than uploading
# it by hand -- then `tofu destroy` removes it, instead of leaving an orphan in
# the account whose id lives only in someone's notes. Both bundled tofu configs
# take an `ssh_public_key` variable for exactly this.

set -Eeuo pipefail

cmd=${1:-help}
dir=${2:-${EPHEMERAL_SSH_DIR:-$PWD/.ssh}}
# ssh(1) needs an absolute path for IdentityAgent, and OpenTofu is run from
# elsewhere in the tree.
dir=$(cd "$(dirname "$dir")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$dir")" || printf '%s' "$dir")
key="$dir/id_ed25519"
envf="$dir/agent.env"
label=$(basename "$(dirname "$dir")")

# A Unix socket path is capped at ~108 bytes by the kernel, and `ssh-agent -a`
# fails outright above it. Deployment directories nested deep enough to exceed
# that are ordinary, so fall back to a short path keyed by a hash of the
# directory -- still one agent per deployment. The key itself stays in the
# deployment directory, where no such limit applies.
sock="$dir/agent.sock"
if [ ${#sock} -gt 100 ]; then
  sock="${XDG_RUNTIME_DIR:-/tmp}/eph-ssh-$(printf '%s' "$dir" | cksum | cut -d' ' -f1).sock"
fi
# stop must find the socket the agent actually used, not recompute it.
[ -f "$envf" ] && sock=$(grep -o '^EPHEMERAL_SOCK=.*' "$envf" 2>/dev/null | cut -d= -f2- || printf '%s' "$sock")
[ -n "$sock" ] || sock="$dir/agent.sock"

# A failed `start` prints nothing, and `eval "$(... start)"` of an empty string
# succeeds -- leaving the caller silently on their personal agent, which is the
# exact class of quiet wrongness this whole skill is about. Emit `false` on
# stdout so the eval fails loudly instead.
fail() {
  printf 'ephemeral-ssh: %s\n' "$1" >&2
  printf 'false # ephemeral-ssh failed: %s\n' "$1"
  exit 1
}

agent_alive() {
  [ -S "$sock" ] || return 1
  SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1
  # 0 = has identities, 1 = alive but empty, 2 = cannot connect
  [ $? -ne 2 ]
}

start() {
  # Covers every failure path, including the ones before the first explicit
  # check -- `set -e` would otherwise exit with empty stdout, and the caller's
  # `eval ""` succeeds. Any abort must reach the caller as a failed eval.
  trap 'printf "false # ephemeral-ssh failed\n"' ERR

  mkdir -p "$dir" || fail "cannot create $dir"
  chmod 700 "$dir"

  if [ ! -f "$key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "${label}-disposable" -f "$key"
  fi
  chmod 600 "$key"

  if ! agent_alive; then
    # A socket left by a dead agent makes every later connection block on it
    # rather than fail, which is worse than not having one.
    rm -f "$sock"
    ssh-agent -a "$sock" > "$envf" 2>/dev/null \
      || fail "ssh-agent could not listen on $sock (${#sock} bytes)"
    printf 'EPHEMERAL_SOCK=%s\n' "$sock" >> "$envf"
    chmod 600 "$envf"
  fi

  SSH_AUTH_SOCK="$sock" ssh-add "$key" >/dev/null 2>&1 \
    || fail "could not add $key to the agent on $sock"

  # Prove the agent actually holds the key before telling the caller to use it.
  SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1 \
    || fail "agent on $sock holds no identities"

  # ANSIBLE_SSH_ARGS REPLACES Ansible's default rather than extending it, so the
  # connection-multiplexing options have to be repeated here or every task pays
  # for a fresh handshake. IdentityAgent AND IdentitiesOnly are both required --
  # see the host-config trap at the top of this file.
  printf 'export SSH_AUTH_SOCK=%s\n' "$sock"
  grep -o 'SSH_AGENT_PID=[0-9]*' "$envf" | head -1 | sed 's/^/export /'
  printf 'export ANSIBLE_SSH_ARGS=%s\n' \
    "\"-C -o ControlMaster=auto -o ControlPersist=60s -o IdentityAgent=$sock -o IdentitiesOnly=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\""
  printf 'ephemeral-ssh: agent %s, key %s\n' "$sock" "$key" >&2
}

stop() {
  if [ -f "$envf" ]; then
    # shellcheck disable=SC1090
    SSH_AGENT_PID=$(grep -o 'SSH_AGENT_PID=[0-9]*' "$envf" | head -1 | cut -d= -f2)
    [ -n "${SSH_AGENT_PID:-}" ] && SSH_AGENT_PID="$SSH_AGENT_PID" ssh-agent -k >/dev/null 2>&1 || true
  fi
  rm -f "$sock" "$envf" "$key" "$key.pub"
  printf 'stopped; key and agent removed from %s\n' "$dir" >&2
  printf 'unset SSH_AUTH_SOCK SSH_AGENT_PID ANSIBLE_SSH_ARGS\n'
}

case "$cmd" in
  start)  start ;;
  pubkey) cat "$key.pub" ;;
  status)
    if agent_alive; then
      printf 'agent alive on %s\n' "$sock"
      SSH_AUTH_SOCK="$sock" ssh-add -l || true
    else
      printf 'no live agent at %s\n' "$sock"
    fi
    [ -f "$key" ] && printf 'key present: %s\n' "$key" || printf 'no key at %s\n' "$key"
    ;;
  stop)   stop ;;
  *)      sed -n '/^# USAGE/,/^# Register/p' "$0" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
