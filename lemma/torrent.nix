{ config, lib, pkgs, ... }: let
	torrent = "torrent.amartia.online";
	netns = "/run/netns/mullvad";
	rpc = 9091; # inside the namespace
	proxy = "127.0.0.1:9092"; # outside it, for caddy; authelia has 9091

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';

	state = "/var/lib/mullvad";
	api = "https://api.mullvad.net";

	# the shell shared by bringing the tunnel up and switching relays.
	# mullvad knows lemma0 as a device: its key is made here, and mullvad
	# hands out the tunnel's addresses for it. relays come from mullvad's
	# public list, so neither the account's device nor the relay in use
	# appears in this repository
	common = ''
		set -euo pipefail
		say() { echo "mullvad: $*" >&2; }
		die() { say "$*"; exit 1; }

		# a working relay among those ${state}/prefer names, or any. each line
		# of it is a hostname or its start: se-got, ch-, de-fra-wg-001
		connect() {
			local relays relay pk host old p
			relays=$(jq -c --rawfile prefer ${state}/prefer '
				($prefer | [splits("\\s+")] | map(select(. != ""))) as $p
				| .wireguard.relays[] | select(.active)
				| select(($p | length) == 0
					or (.hostname as $h | $p | any(. as $q | $h | startswith($q))))
				| {hostname, public_key, ipv4_addr_in}
			' ${state}/relays.json 2>/dev/null ||
				jq -c '.wireguard.relays[] | select(.active)
					| {hostname, public_key, ipv4_addr_in}' ${state}/relays.json)
			[ -n "$relays" ] || die "no relay matches ${state}/prefer"
			old=$(ip netns exec mullvad wg show mullvad peers)

			# up to five of them, each at most once
			while read -r relay; do
				pk=$(jq -r .public_key <<<"$relay")
				host=$(jq -r .hostname <<<"$relay")
				ip netns exec mullvad wg set mullvad peer "$pk" \
					endpoint "$(jq -r .ipv4_addr_in <<<"$relay"):51820" \
					allowed-ips 0.0.0.0/0,::/0
				for p in $old; do
					[ "$p" = "$pk" ] || ip netns exec mullvad wg set mullvad peer "$p" remove
				done
				old=$pk
				# mullvad's resolver answers pings once the handshake is through
				if ip netns exec mullvad ping -q -c 3 -W 3 10.64.0.1 >/dev/null; then
					echo "$host" >/run/mullvad/relay
					say "through $host"
					return 0
				fi
				say "$host doesn't answer"
			done < <(shuf -n 5 <<<"$relays")
			die "no relay answered"
		}
	'';

	# register lemma0's key once, and keep the relay list fresh. both are
	# kept, so an unreachable api only means the last ones are used
	register = ''
		key=$CREDENTIALS_DIRECTORY/key
		hdr=$(mktemp); trap 'rm -f "$hdr"' EXIT
		post() { curl -sSf --retry 3 -H 'content-type: application/json' --data @- "$@"; }
		pub=$(wg pubkey <"$key")
		if jq -Rn '{account_number: (input | gsub("\\s"; ""))}' \
				<"$CREDENTIALS_DIRECTORY/account" |
				post ${api}/auth/v1/token |
				jq -er '"Authorization: Bearer \(.access_token)"' >"$hdr"; then
			device=$(curl -sSf --retry 3 -H @"$hdr" ${api}/accounts/v1/devices |
				jq -c --arg p "$pub" 'map(select(.pubkey == $p))[0] // empty')
			if [ -z "$device" ]; then
				device=$(jq -nc --arg p "$pub" '{pubkey: $p, hijack_dns: false}' |
					post -H @"$hdr" ${api}/accounts/v1/devices)
				say "registered as $(jq -r .name <<<"$device")"
			fi
			jq '{name, ipv4_address, ipv6_address}' <<<"$device" >${state}/device.json.new
			mv ${state}/device.json.new ${state}/device.json
			curl -sSf --retry 3 ${api}/public/relays/wireguard/v2 >${state}/relays.json.new
			mv ${state}/relays.json.new ${state}/relays.json
		else
			say "mullvad's api is unreachable or refused; using the last registration"
		fi
		[ -s ${state}/device.json ] && [ -s ${state}/relays.json ] ||
			die "never registered with mullvad"
	'';

	# a namespace with nothing but loopback and the tunnel: when mullvad is
	# down there is no route at all, so nothing leaks around it. the tunnel's
	# udp socket stays outside, since the interface is made there and moved in
	up = pkgs.writeShellScript "mullvad-up" ''
		${common}
		${register}
		touch ${state}/prefer

		ip netns delete mullvad 2>/dev/null || true
		ip link delete mullvad 2>/dev/null || true
		ip netns add mullvad
		ip -n mullvad link set lo up

		ip link add mullvad type wireguard
		wg set mullvad private-key "$key"
		ip link set mullvad netns mullvad
		for a in $(jq -r '.ipv4_address, .ipv6_address' ${state}/device.json); do
			ip -n mullvad address add "$a" dev mullvad
		done
		ip -n mullvad link set mullvad up
		ip -n mullvad -4 route add default dev mullvad
		ip -n mullvad -6 route add default dev mullvad

		# mullvad's resolver, inside the tunnel
		install -d -m 755 /run/mullvad
		echo "nameserver 10.64.0.1" >/run/mullvad/resolv.conf

		connect
	'';

	# another relay without tearing the namespace down: only the peer
	# changes, so transmission keeps running and reconnects to its peers
	switch = pkgs.writeShellScript "mullvad-switch" ''
		${common}
		connect
	'';

	tools = with pkgs; [ iproute2 iputils wireguard-tools jq curl coreutils ];
in {
	# lux's account number, the only credential mullvad has. its devices are
	# listed (and removed) at mullvad.net/account
	crypt.secrets.mullvad.text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0ACUhmBoCkFnpK8cfy2TTf3mkxm
		hA6FneiZfZfd00DwQTDX9PWQRZ6xJqNwlUtkVgVumEl4uXsUz6xh2LJXr+VH58wg
		HKKBiFz9L+7LrWWduX7BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQIJ2Xvl7
		uuCyndVsyqWMPXMX/Ta5iYdojY2DhTp6AfhFMCA4ckvhOc+Stxdbg2vBYa8wqyhF
		J1eLUU0iZzC0Cl/DCDdJBgNaqOG8gG7evbuPBdJeAgkCBgaFUDU8uy0MNbPxYIv0
		JP3lHi4DkJPMZF73L1iKF+h94TSsyLJ6kVUvcwhqizYFdek+PYyyaJV5DSt0TI+T
		opFllYZeghM8Fi47CTKMy8PIZuSXuka4FHa/5Q==
		-----END PGP MESSAGE-----
	'';
	crypt.secrets.mullvad.services = [ "mullvad" ];
	# lemma0's own wireguard key, registered with mullvad at first start
	crypt.generated.mullvad-key.script =
		"${pkgs.wireguard-tools}/bin/wg genkey | tr -d '\\n' >$out";

	systemd.services.mullvad = {
		description = "network namespace that only reaches the internet through mullvad";
		wants = [ "network-online.target" ];
		after = [ "network-online.target" ];
		path = tools;
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
			StateDirectory = "mullvad";
			LoadCredential = [
				"account:${config.crypt.secrets.mullvad.path}"
				"key:${config.crypt.generated.mullvad-key.path}"
			];
			ExecStart = up;
			ExecStop = "${pkgs.iproute2}/bin/ip netns delete mullvad";
			Restart = "on-failure";
			RestartSec = "1min";
		};
	};
	# `systemctl start mullvad-switch` after editing /var/lib/mullvad/prefer,
	# or to move on from a relay
	systemd.services.mullvad-switch = {
		description = "switch mullvad relays";
		requisite = [ "mullvad.service" ];
		after = [ "mullvad.service" ];
		path = tools;
		serviceConfig = {
			Type = "oneshot";
			ExecStart = switch;
		};
	};

	services.transmission = {
		enable = true;
		package = pkgs.transmission_4;
		settings = {
			# everything goes to witness0 (lemma/box.nix), partial torrents too,
			# so transmission can't fill lemma0's own disk, which the databases
			# of every other service live on. pick a subdirectory per kind when
			# adding a torrent; video/ is the one kino can link to
			download-dir = "/srv/seed";
			incomplete-dir-enabled = false;
			# and nothing reserved ahead: transmission's default preallocation
			# ("sparse") still calls fallocate, which takes each file's whole
			# size at once. files grow as pieces come in, holes cost nothing
			preallocation = 0;
			# pieces reach the box in larger writes, through gocryptfs and smb
			cache-size-mb = 64;
			rpc-bind-address = "127.0.0.1";
			rpc-port = rpc;
			# authelia stands in front; transmission only sees the proxy
			rpc-authentication-required = false;
			rpc-whitelist-enabled = true;
			rpc-whitelist = "127.0.0.1";
			rpc-host-whitelist-enabled = true;
			rpc-host-whitelist = torrent;
			# mullvad forwards no ports, so peers can't reach us; we reach them
			port-forwarding-enabled = false;
			encryption = 1; # prefer encrypted peers
		};
	};

	systemd.services.transmission = {
		unitConfig.RequiresMountsFor = [ "/srv/seed" "/srv/seed/video" ];
		bindsTo = [ "mullvad.service" ];
		after = [ "mullvad.service" ];
		serviceConfig = {
			NetworkNamespacePath = netns;
			# joining a namespace the host's user namespace owns needs
			# privileges a private user namespace wouldn't have
			PrivateUsers = false;
			# names resolve through mullvad's resolver, not the host's: glibc
			# loses nscd (and resolved behind it) and reads the stub's file,
			# which is mullvad's here
			InaccessiblePaths = [ "-/run/nscd" "-/run/systemd/resolve/io.systemd.Resolve" ];
			BindReadOnlyPaths = [ "/run/mullvad/resolv.conf:/run/systemd/resolve/stub-resolv.conf" ];
		};
	};

	# the web ui and rpc, carried out of the namespace: the socket is the
	# host's, the proxy connects from inside
	systemd.sockets.transmission-rpc = {
		wantedBy = [ "sockets.target" ];
		listenStreams = [ proxy ];
	};
	systemd.services.transmission-rpc = {
		requires = [ "transmission.service" ];
		bindsTo = [ "mullvad.service" ];
		after = [ "transmission.service" "mullvad.service" ];
		serviceConfig = {
			ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString rpc}";
			NetworkNamespacePath = netns;
			DynamicUser = true;
		};
	};

	# who may: members of `torrent`, added in lldap's ui
	lldap.groups = [ "torrent" ];
	invite.groups.torrent = {
		label = "Torrents";
		info = "https://${torrent}, after a second factor you set up on first login";
	};
	services.authelia.instances.main.settings.access_control.rules = [{
		domain = torrent;
		subject = [ "group:torrent" ];
		policy = "two_factor";
	}];

	services.caddy.virtualHosts.${torrent}.extraConfig = ''
		forward_auth 127.0.0.1:9091 {
			uri /api/authz/forward-auth
			copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
		}
		reverse_proxy ${proxy}
	'';
}
