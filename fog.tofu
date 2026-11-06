terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

variable "hcloud_token" { sensitive = true }
provider "hcloud" { token = var.hcloud_token }

resource "hcloud_primary_ip" "dew0" {
	datacenter = "nbg1-dc3"
	name = "dew0"
	type = "ipv6"
	assignee_type = "server"
	auto_delete = false
	# hetzner's api no longer reports a datacenter, and the provider reads the
	# missing one as a change that forces a new resource. these three must
	# never be replaced: dew0_4 is deleted with its server
	lifecycle {
		ignore_changes = [datacenter]
		prevent_destroy = true
	}
}

resource "hcloud_primary_ip" "dew0_4" {
	datacenter = "nbg1-dc3"
	name = "dew0_4"
	type = "ipv4"
	assignee_type = "server"
	auto_delete = true
	lifecycle {
		ignore_changes = [datacenter]
		prevent_destroy = true
	}
}

resource "hcloud_server" "lemma0" {
	datacenter = "nbg1-dc3"
	name = "lemma0"
	server_type = "ccx13"
	image = "debian-13"
	public_net {
		ipv6_enabled = true
		ipv6 = hcloud_primary_ip.dew0.id
		ipv4_enabled = true
		ipv4 = hcloud_primary_ip.dew0_4.id
	}
	lifecycle {
		ignore_changes = [datacenter]
		prevent_destroy = true
	}
}

# dns for both domains, moved from namecheap. every name that has any record
# of its own needs its addresses spelled out: the wildcard stops answering
# for a name as soon as it exists (rfc 4592), which is what broke mx once
locals {
	ipv4 = hcloud_primary_ip.dew0_4.ip_address
	ipv6 = cidrhost(hcloud_primary_ip.dew0.ip_network, 1)
	mx = "mx.amartia.online."

	# stalwart's keys, from "view dns records" on each domain
	dkim = {
		"amartia.online" = {
			"202611r" = "v=DKIM1; k=rsa; h=sha256; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq8hsoBcKhwSFgFAJCkbXRU4CFLm9anwAbxUmr/obGoTIVdDjNdWfb/KQNaDNKOLtsjLRpmMKb6nbOIyyVehCJQS2dIDRVu0x+aZ9hw5FPP4VLBOXt1rx3ZGQjMtT63fZh2hmMiCjQpn72L2n5JYBRp2/QZSp6GqR4Jo3YHxqseGQZtNNSD/SX75mmumCsW4hUj1zzwnGt2V1RtUBVE7PsdekR6g3r8TGMd2Pxe6Agu78U/gszC2Ha7SXYkt2hndO1l1iwig+xoWYik1MfJCiNI+siexI/7jmkAl3g1AIRhcI2CBUVlwKkVgR5UTjJxq6kSAGat39yPJVuxq3lJxWmQIDAQAB"
			"202611e" = "v=DKIM1; k=ed25519; h=sha256; p=mYApLwASTd3LTvSsMpd4Zm1/Di8i4s0qPZ4zRb6xabM="
		}
		"cpli.dev" = {
			"202611r" = "v=DKIM1; k=rsa; h=sha256; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA20roXrIxTtbFNotWAghvHnKQdpeiLk1sUB+bg9a8/hyAyHfMRTUp+UueZ1J8tzBWgvrxDpMym7qH6a06Wrz9GLPfGnqVgSC7Le7HfslOQKcbRTb2m9GOd3ZdUdb407uksNVaYhFlDIvt94SjIyH2yK+t07aosjJptgmPc6wBcbca8pYsDLRSCwKF6b76A5Ycth77+AvuhEpbU/XT+xO8OI/OiGy0baSo2EsgKS5Pltn52epjrov1HhDvTJP3hbcbTvFkpbdH5g+r59eE4C9FjgH19xs3hJ9XYjyw66azDAKyNCNquwbWGMjhMnThmF/h6pUnbRpgzx8z1nL08ZVixQIDAQAB"
			"202611e" = "v=DKIM1; k=ed25519; h=sha256; p=DQfDBzHdmIVpWjCAQj+pyyaH0kJqWCTrc8DmMymLnVU="
		}
	}

	# zone → name → type → values. both domains are served by lemma0 alike
	zones = { for zone, keys in local.dkim : zone => merge(
		{
			"@" = {
				A = [local.ipv4]
				AAAA = [local.ipv6]
				MX = ["10 ${local.mx}"]
				TXT = ["v=spf1 mx ra=postmaster -all"]
			}
			"*" = { A = [local.ipv4], AAAA = [local.ipv6] }
			"mail" = { CNAME = [local.mx] }
			"_dmarc" = { TXT = [join("; ", [
				"v=DMARC1", "p=reject",
				"rua=mailto:postmaster@${zone}", "ruf=mailto:postmaster@${zone}",
			])] }
			"_smtp._tls" = { TXT = ["v=TLSRPTv1; rua=mailto:postmaster@${zone}"] }
			# client discovery (rfc 6186, 8314, 6764)
			"_imaps._tcp" = { SRV = ["0 1 993 ${local.mx}"] }
			"_submissions._tcp" = { SRV = ["0 1 465 ${local.mx}"] }
			"_submission._tcp" = { SRV = ["0 1 587 ${local.mx}"] }
			"_caldavs._tcp" = { SRV = ["0 1 443 ${local.mx}"] }
			"_carddavs._tcp" = { SRV = ["0 1 443 ${local.mx}"] }
		},
		{ for selector, key in keys : "${selector}._domainkey" => { TXT = [key] } },
		zone == "amartia.online" ? {
			"mx" = {
				A = [local.ipv4]
				AAAA = [local.ipv6]
				TXT = ["v=spf1 a ra=postmaster -all"]
			}
		} : {},
	) }

	rrsets = merge([
		for zone, names in local.zones : merge([
			for name, types in names : {
				for type, values in types : "${zone} ${name} ${type}" => {
					zone = zone, name = name, type = type, values = values
				}
			}
		]...)
	]...)
}

resource "hcloud_zone" "zone" {
	for_each = local.dkim
	name = each.key
	mode = "primary"
}

resource "hcloud_zone_rrset" "rrset" {
	for_each = local.rrsets
	zone = hcloud_zone.zone[each.value.zone].name
	name = each.value.name
	type = each.value.type
	# txt values go up quoted, split into strings of 255 characters
	records = [for value in each.value.values : {
		value = (each.value.type == "TXT"
			? provider::hcloud::txt_record(value) : value)
	}]
}

# stalwart greets as mx, so both addresses must point back to it
resource "hcloud_rdns" "ipv4" {
	primary_ip_id = hcloud_primary_ip.dew0_4.id
	ip_address = local.ipv4
	dns_ptr = trimsuffix(local.mx, ".")
}

resource "hcloud_rdns" "ipv6" {
	primary_ip_id = hcloud_primary_ip.dew0.id
	ip_address = local.ipv6
	dns_ptr = trimsuffix(local.mx, ".")
}

# set these at namecheap (domain → nameservers → custom dns) once applied
output "nameservers" {
	value = { for zone, z in hcloud_zone.zone : zone => z.authoritative_nameservers }
}
