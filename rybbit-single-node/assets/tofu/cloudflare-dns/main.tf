## Cloudflare DNS for a single-node Rybbit stack.  VERIFIED.
##
## Independent of the compute provider: it takes an address and publishes a
## record, and works unchanged behind DigitalOcean, Vultr or anything else.
##
## Credentials come from CLOUDFLARE_API_TOKEN in the environment.

terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }
}

provider "cloudflare" {}

variable "host" {
  description = "Fully qualified hostname, e.g. rybbit.example.com."
  type        = string
}

variable "zone" {
  description = <<-EOT
    The registrable zone, e.g. example.com. Defaults to everything after the
    first label. Filtering the zone lookup by the fully qualified host instead
    of the zone is why an earlier version could never match one -- set this
    explicitly when the heuristic is wrong.
  EOT
  type        = string
  default     = null
}

variable "ip" {
  description = "The address the compute layer emitted."
  type        = string
}

variable "proxied" {
  description = <<-EOT
    Proxied by default. An unproxied record publishes the machine's address and
    leaves the firewall as the only thing in front of the origin.

    The Caddyfile already trusts Cloudflare's ranges, so client addresses still
    come from X-Forwarded-For and geo and ASN attribution are unaffected --
    verified against a live deployment.

    The cost: SSH to the hostname stops resolving to the machine. Converges are
    unaffected because Ansible uses the address the provider emitted, but an
    ad-hoc ssh needs the origin address.
  EOT
  type        = bool
  default     = true
}

locals {
  zone_name = var.zone != null ? var.zone : join(".", slice(
    split(".", var.host), 1, length(split(".", var.host))
  ))
}

data "cloudflare_zone" "zone" {
  filter = { name = local.zone_name }
}

resource "cloudflare_dns_record" "rybbit" {
  zone_id = data.cloudflare_zone.zone.zone_id
  name    = var.host
  content = var.ip
  type    = "A"
  proxied = var.proxied
  ttl     = 1
}

output "host" {
  value = var.host
}
