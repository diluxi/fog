terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      # 1.66: storage boxes with named subaccounts, and still `datacenter`,
      # which 1.67 removed. moving to `location` comes before going past it
      version = "~> 1.66.0"
    }
    # passwords nobody types, for witness0
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
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

# witness0: storage for lemma0, which has 80GB of its own. storage boxes only
# exist in fsn1 and hel1; nbg1 is a few milliseconds away. the box's own
# account reaches nothing; lemma0 mounts through a subaccount that only sees
# srv/, so a later subaccount (backups, say) stays out of its reach.
#
# both passwords are made here and kept only in tofu's state: password logins
# can't be turned off on a storage box, and nobody types either one.
# `fog witness` hands the subaccount's to lemma0, encrypted
resource "random_password" "witness0" {
	length = 32
	# hetzner doesn't say what it accepts; plain ascii is known to work
	override_special = "-_"
	min_upper = 1
	min_lower = 1
	min_numeric = 1
	min_special = 1
}

resource "random_password" "witness0_srv" {
	length = 32
	override_special = "-_"
	min_upper = 1
	min_lower = 1
	min_numeric = 1
	min_special = 1
}

resource "hcloud_storage_box" "witness0" {
	name = "witness0"
	storage_box_type = "bx21"
	location = "fsn1"
	password = random_password.witness0.result
	delete_protection = true
	access_settings = {
		samba_enabled = false
		ssh_enabled = false
		webdav_enabled = false
		zfs_enabled = false # no .zfs in jellyfin's libraries
		reachable_externally = false
	}
	lifecycle { prevent_destroy = true }
}

# lemma0's /srv/seed and /srv/kino, as srv/seed and srv/kino on the box
resource "hcloud_storage_box_subaccount" "witness0_srv" {
	storage_box_id = hcloud_storage_box.witness0.id
	name = "srv"
	description = "lemma0: /srv/seed and /srv/kino"
	home_directory = "srv"
	password = random_password.witness0_srv.result
	access_settings = {
		samba_enabled = true
		ssh_enabled = false
		webdav_enabled = false
		reachable_externally = false
	}
}

# what lemma/box.nix mounts with, through `fog witness`
output "witness0_srv" {
	value = {
		server = hcloud_storage_box_subaccount.witness0_srv.server
		username = hcloud_storage_box_subaccount.witness0_srv.username
	}
}
output "witness0_srv_credentials" {
	sensitive = true
	value = "username=${hcloud_storage_box_subaccount.witness0_srv.username}\npassword=${random_password.witness0_srv.result}\n"
}

# dns for every dns/<zone>.zone. the hcloud provider takes no zone files, so
# their records are parsed here, one per line, into one rrset per name and
# type. tofu has no zone file parser; this one only reads the subset the
# files' headers describe
locals {
	ipv4 = hcloud_primary_ip.dew0_4.ip_address
	ipv6 = cidrhost(hcloud_primary_ip.dew0.ip_network, 1)
	mx = "mx.amartia.online."

	zones = toset([for f in fileset("${path.module}/dns", "*.zone") :
		trimsuffix(f, ".zone")])

	records = flatten([for zone in local.zones : [
		for line in split("\n", file("${path.module}/dns/${zone}.zone")) :
		merge({ zone = zone }, regex(join("", [
			"^(?P<name>\\S+)\\s+(?:(?P<ttl>\\d+)\\s+)?(?:IN\\s+)?",
			"(?P<type>[A-Z]+)\\s+(?P<value>.*?)\\s*$",
		]), line))
		if trimspace(line) != "" && !startswith(trimspace(line), ";")
	]])

	rrsets = { for r in local.records : "${r.zone} ${r.name} ${r.type}" => r... }
}

resource "hcloud_zone" "zone" {
	for_each = local.zones
	name = each.key
	mode = "primary"
}

resource "hcloud_zone_rrset" "rrset" {
	for_each = local.rrsets
	zone = hcloud_zone.zone[each.value[0].zone].name
	name = each.value[0].name
	type = each.value[0].type
	ttl = try(tonumber(each.value[0].ttl), null)
	# a txt value's strings are joined and split again at 255 characters,
	# so a key can be pasted as one string
	records = [for r in each.value : {
		value = (r.type == "TXT"
			? provider::hcloud::txt_record(
				join("", flatten(regexall("\"([^\"]*)\"", r.value))))
			: r.value)
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
