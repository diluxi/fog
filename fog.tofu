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
}

resource "hcloud_primary_ip" "dew0_4" {
	datacenter = "nbg1-dc3"
	name = "dew0_4"
	type = "ipv4"
	assignee_type = "server"
	auto_delete = true
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
}
