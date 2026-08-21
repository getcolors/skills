## Vultr compute for a single-node Rybbit stack.
##
## ############################################################################
## ## NOT YET CONVERGED. No machine has been created from this file.         ##
## ##                                                                        ##
## ## What IS checked: `tofu validate` passes against the real vultr/vultr   ##
## ## provider schema (v2.32.0), so every resource type, attribute name and  ##
## ## type here is correct rather than remembered.                           ##
## ##                                                                        ##
## ## What is NOT checked: anything the API decides at apply time -- plan     ##
## ## and region availability, whether the OS filter matches exactly one     ##
## ## image, and the behaviour claims in the comments below. Run `tofu plan` ##
## ## against your account, converge, run scripts/acceptance.sh, and then    ##
## ## delete this banner.                                                    ##
## ############################################################################
##
## It satisfies the same contract as the DigitalOcean file: one Ubuntu machine,
## inbound 22/80/443 only, and an IPv4 address exported as `params`. Nothing
## above the provider layer changes. See references/providers.md.
##
## Credentials come from VULTR_API_KEY in the environment.

terraform {
  required_providers {
    vultr = { source = "vultr/vultr", version = "~> 2.0" }
  }
}

provider "vultr" {}

variable "name" {
  description = "Deployment name. Used as the console label and passed to the converge as the hostname."
  type        = string
  default     = "rybbit"
}

variable "region" {
  description = "Vultr region id, e.g. ams, ewr, sea."
  type        = string
  default     = "ams"
}

variable "plan" {
  description = "Vultr plan id. vc2-2c-4gb is the rough equivalent of the verified s-2vcpu-4gb."
  type        = string
  default     = "vc2-2c-4gb"
}

variable "os_name" {
  description = "Matched against the OS list by name, so no numeric id is hardcoded here."
  type        = string
  default     = "Ubuntu 24.04 LTS x64"
}

variable "ssh_key_ids" {
  description = "Existing Vultr SSH key IDs to install for root. May be empty when ssh_public_key is set."
  type        = list(string)
  default     = []
}

# A disposable key, registered as a resource so `tofu destroy` removes it from
# the account. Uploading one by hand leaves an orphan whose id survives only in
# someone's notes. Generate with scripts/ephemeral-ssh.sh:
#
#   eval "$(scripts/ephemeral-ssh.sh start)"
#   tofu apply -var "ssh_public_key=$(scripts/ephemeral-ssh.sh pubkey)"
variable "ssh_public_key" {
  description = "Optional public key to register and attach. Created and destroyed with the stack."
  type        = string
  default     = null
}

resource "vultr_ssh_key" "disposable" {
  count   = var.ssh_public_key == null ? 0 : 1
  name    = "${var.name}-disposable"
  ssh_key = var.ssh_public_key
}

locals {
  ssh_key_ids = concat(var.ssh_key_ids, vultr_ssh_key.disposable[*].id)
}

# Vultr splits a CIDR into an address and a prefix length, one rule at a time,
# per IP version -- unlike DigitalOcean, which takes a list of CIDRs per rule.
# "0.0.0.0/0" is subnet "0.0.0.0" with subnet_size 0.
variable "ssh_sources" {
  description = "Objects of {subnet, subnet_size, ip_type} allowed to reach SSH."
  type        = list(object({ subnet = string, subnet_size = number, ip_type = string }))
  default = [
    { subnet = "0.0.0.0", subnet_size = 0, ip_type = "v4" },
    { subnet = "::", subnet_size = 0, ip_type = "v6" },
  ]
}

variable "http_sources" {
  description = "Objects of {subnet, subnet_size, ip_type} allowed to reach 80/443."
  type        = list(object({ subnet = string, subnet_size = number, ip_type = string }))
  default = [
    { subnet = "0.0.0.0", subnet_size = 0, ip_type = "v4" },
    { subnet = "::", subnet_size = 0, ip_type = "v6" },
  ]
}

# Vultr can populate Cloudflare's edge ranges itself, via `source = "cloudflare"`
# on a rule. If you serve the origin through Cloudflare -- which the bundled DNS
# config does by default -- that is a stronger posture than opening 80/443 to
# the world, and it costs one attribute. It locks out direct origin access, so
# keep SSH reachable and remember it when debugging.
variable "http_cloudflare_only" {
  description = "Replace the http_sources rules with a single Cloudflare-sourced rule per port."
  type        = bool
  default     = false
}

data "vultr_os" "ubuntu" {
  filter {
    name   = "name"
    values = [var.os_name]
  }
}

resource "vultr_firewall_group" "rybbit" {
  description = "${var.name} firewall"
}

# Vultr firewalls are default-deny inbound and do not model outbound at all, so
# there are no outbound rules to write here -- unlike the DigitalOcean file,
# which needs three of them to avoid cutting the machine off.

resource "vultr_firewall_rule" "ssh" {
  for_each          = { for i, s in var.ssh_sources : i => s }
  firewall_group_id = vultr_firewall_group.rybbit.id
  protocol          = "tcp"
  ip_type           = each.value.ip_type
  subnet            = each.value.subnet
  subnet_size       = each.value.subnet_size
  port              = "22"
  notes             = "ssh"
}

resource "vultr_firewall_rule" "http" {
  for_each = var.http_cloudflare_only ? {} : {
    for t in setproduct(["tcp", "udp"], ["80", "443"], range(length(var.http_sources))) :
    "${t[0]}-${t[1]}-${t[2]}" => { proto = t[0], port = t[1], src = var.http_sources[t[2]] }
    # UDP 443 carries HTTP/3, which Caddy advertises via alt-svc whether or not
    # the port is open; without it browsers try QUIC, fail, and fall back to
    # TCP, so it surfaces as intermittent slowness. UDP 80 is unused and is
    # filtered out by the condition here.
    if !(t[0] == "udp" && t[1] == "80")
  }
  firewall_group_id = vultr_firewall_group.rybbit.id
  protocol          = each.value.proto
  ip_type           = each.value.src.ip_type
  subnet            = each.value.src.subnet
  subnet_size       = each.value.src.subnet_size
  port              = each.value.port
  notes             = "http ${each.value.proto}"
}

resource "vultr_firewall_rule" "http_cloudflare" {
  for_each = var.http_cloudflare_only ? {
    "tcp-80"  = { proto = "tcp", port = "80" }
    "tcp-443" = { proto = "tcp", port = "443" }
    "udp-443" = { proto = "udp", port = "443" }
  } : {}
  firewall_group_id = vultr_firewall_group.rybbit.id
  protocol          = each.value.proto
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = each.value.port
  source            = "cloudflare"
  notes             = "http ${each.value.proto} via cloudflare"
}

resource "vultr_instance" "rybbit" {
  region            = var.region
  plan              = var.plan
  os_id             = data.vultr_os.ubuntu.id
  label             = var.name
  ssh_key_ids       = local.ssh_key_ids
  firewall_group_id = vultr_firewall_group.rybbit.id
  enable_ipv6       = true
  activation_email  = false

  # `hostname` is deliberately NOT set. The provider documents a hostname change
  # as force-new because the API implements it as an OS reinstall -- so the one
  # operation that is harmless on DigitalOcean destroys the machine here. The
  # playbook sets the hostname on the running system instead.

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length(local.ssh_key_ids) > 0
      error_message = "Set ssh_key_ids, ssh_public_key, or both -- otherwise the machine is created and nothing can reach it."
    }
  }
}

output "params" {
  value = {
    # main_ip, not ipv4_address. Getting this name wrong is the most likely
    # error when porting, and it fails as an unreachable host rather than as a
    # missing output.
    ip     = vultr_instance.rybbit.main_ip
    user   = "root"
    sudoer = "root"
    name   = var.name
  }
}
