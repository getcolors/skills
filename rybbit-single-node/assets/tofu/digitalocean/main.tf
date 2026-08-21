## DigitalOcean compute for a single-node Rybbit stack.  VERIFIED.
##
## This is the implementation the whole skill was verified against. It satisfies
## the provider contract in references/providers.md: one Ubuntu machine, inbound
## 22/80/443 only, outbound open, and an IPv4 address exported as `params`.
##
## Credentials come from DIGITALOCEAN_TOKEN in the environment.

terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
  }
}

provider "digitalocean" {}

variable "name" {
  description = "Deployment name. Names the machine and its firewall; keep it stable."
  type        = string
  default     = "rybbit"
}

variable "region" {
  type    = string
  default = "ams3"
}

# Measured on the running stack: six containers, ~1.0GB resident, 6.2GB disk.
# Size up reluctantly -- a larger plan's disk is what makes it impossible to
# leave later. See references/providers.md.
variable "size" {
  type    = string
  default = "s-2vcpu-4gb"
}

variable "image" {
  type    = string
  default = "ubuntu-24-04-x64"
}

variable "ssh_keys" {
  description = "Existing DigitalOcean SSH key IDs or fingerprints. May be empty when ssh_public_key is set."
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

resource "digitalocean_ssh_key" "disposable" {
  count      = var.ssh_public_key == null ? 0 : 1
  name       = "${var.name}-disposable"
  public_key = var.ssh_public_key
}

locals {
  ssh_keys = concat(var.ssh_keys, digitalocean_ssh_key.disposable[*].fingerprint)
}

variable "ssh_sources" {
  description = "CIDRs allowed to reach SSH. Narrow this if you can."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "http_sources" {
  description = "CIDRs allowed to reach 80/443. Cloudflare's ranges if you lock the origin."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

# Discover the region's account default at plan time. The UUID is deliberately
# neither configured nor persisted, so the same file works in another account.
data "digitalocean_vpc" "default" {
  name = "default-${var.region}"
}

resource "digitalocean_droplet" "rybbit" {
  name     = var.name
  region   = var.region
  size     = var.size
  image    = var.image
  vpc_uuid = data.digitalocean_vpc.default.id
  ssh_keys = local.ssh_keys

  # Renaming is an in-place operation here: the droplet keeps its address and
  # volumes. That is a DigitalOcean property, not a general one.
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length(local.ssh_keys) > 0
      error_message = "Set ssh_keys, ssh_public_key, or both -- otherwise the droplet is created and nothing can reach it."
    }
  }
}

resource "digitalocean_firewall" "rybbit" {
  name        = "${var.name}-firewall"
  droplet_ids = [digitalocean_droplet.rybbit.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_sources
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = var.http_sources
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = var.http_sources
  }
  # HTTP/3. Caddy advertises it via alt-svc whether or not this is open, so
  # without it browsers try QUIC, fail, and fall back to TCP -- intermittent
  # slowness rather than a clean error.
  inbound_rule {
    protocol         = "udp"
    port_range       = "443"
    source_addresses = var.http_sources
  }

  # Explicit and required: DigitalOcean firewalls deny outbound once a firewall
  # is attached, and image pulls, ACME and the backup upload all need it.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  lifecycle { prevent_destroy = true }
}

output "params" {
  value = {
    ip     = digitalocean_droplet.rybbit.ipv4_address
    user   = "root"
    sudoer = "root"
    name   = var.name
  }
}
