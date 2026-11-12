{ config, lib, pkgs, ... }: let
	torrent = "torrent.amartia.online";
	netns = "/run/netns/airvpn";
	rpc = 9091; # inside the namespace
	proxy = 9092; # outside it, for caddy (authelia has 9091) and the vpn

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. ${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';

	state = "/var/lib/airvpn";
	run = "/run/airvpn";
	status = "https://airvpn.org/api/status/";

	# the shell shared by bringing the tunnel up and switching servers.
	# airvpn knows lemma0 as a device, whose keys and tunnel addresses are
	# the config from its client area (crypt.secrets.airvpn). every server
	# shares one key and the port is the account's, so a server is only an
	# endpoint, chosen from airvpn's public status at run time: neither the
	# device nor the server in use appears in this repository
	common = ''
		set -euo pipefail
		say() { echo "airvpn: $*" >&2; }
		die() { say "$*"; exit 1; }

		# a value from the device's wg-quick config
		conf() {
			sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" \
				"$CREDENTIALS_DIRECTORY/conf" | head -n 1 | tr -d '[:space:]'
		}

		# a server that answers, among the healthy ones ${state}/prefer names,
		# or any healthy one; the least loaded first, skipping the one in use
		# when switching. each line of prefer is a server's name, a country
		# code or a city, in any case: Achernar, nl, Zurich
		connect() {
			local servers server name pk psk ka before
			servers=$(jq -c --rawfile prefer ${state}/prefer \
					--arg skip "$(cat ${run}/server 2>/dev/null || true)" '
				($prefer | ascii_downcase | [splits("\\s+")] | map(select(. != ""))) as $p
				| [.servers[] | select(.health == "ok" and .public_name != $skip)
					| select(($p | length) == 0 or ([.public_name, .country_code, .location]
						| map(ascii_downcase) | any(. as $v | $p | index($v) != null)))]
				| sort_by(.currentload) | .[:5][]
				| {public_name, ip_v4_in1, currentload}
			' ${state}/status.json)
			[ -n "$servers" ] || die "no healthy server matches ${state}/prefer"
			pk=$(conf PublicKey)
			psk=$(conf PresharedKey)
			ka=$(conf PersistentKeepalive)
			umask 077
			printf '%s\n' "$psk" >${run}/psk

			while read -r server; do
				name=$(jq -r .public_name <<<"$server")
				# the peer anew, so the old server's session goes with it and
				# the handshake below is the new server's
				ip netns exec airvpn wg set airvpn peer "$pk" remove
				ip netns exec airvpn wg set airvpn peer "$pk" \
					preshared-key ${run}/psk \
					endpoint "$(jq -r .ip_v4_in1 <<<"$server"):1637" \
					persistent-keepalive "''${ka:-15}" \
					allowed-ips 0.0.0.0/0,::/0
				ip netns exec airvpn ping -q -c 1 -W 1 "$(conf DNS | cut -d, -f1)" >/dev/null 2>&1 || true
				for _ in 1 2 3 4 5 6 7 8; do
					if [ "$(ip netns exec airvpn wg show airvpn latest-handshakes | cut -f2)" != 0 ]; then
						echo "$name" >${run}/server
						say "through $name ($(jq -r .currentload <<<"$server")% load)"
						return 0
					fi
					sleep 1
				done
				say "$name doesn't answer"
			done <<<"$servers"
			die "no server answered"
		}
	'';

	# the server list, kept fresh, and the last one kept, so an unreachable
	# api only means older loads
	refresh = ''
		if curl -sSf --retry 3 -m 30 ${status} >${state}/status.json.new &&
				jq -e '.servers | length > 0' ${state}/status.json.new >/dev/null; then
			mv ${state}/status.json.new ${state}/status.json
		else
			rm -f ${state}/status.json.new
			say "airvpn's status api is unreachable; using the last list"
		fi
		[ -s ${state}/status.json ] || die "never got airvpn's server list"
	'';

	# a namespace with nothing but loopback and the tunnel: when airvpn is
	# down there is no route at all, so nothing leaks around it. the tunnel's
	# udp socket stays outside, since the interface is made there and moved in
	up = pkgs.writeShellScript "airvpn-up" ''
		${common}
		install -d -m 755 ${run}
		rm -f ${run}/server
		${refresh}
		touch ${state}/prefer

		ip netns delete airvpn 2>/dev/null || true
		ip link delete airvpn 2>/dev/null || true
		ip netns add airvpn
		ip -n airvpn link set lo up

		ip link add airvpn type wireguard
		(umask 077; conf PrivateKey >${run}/key)
		wg set airvpn private-key ${run}/key
		ip link set airvpn netns airvpn
		for a in $(conf Address | tr , ' '); do
			ip -n airvpn address add "$a" dev airvpn
		done
		ip -n airvpn link set airvpn mtu "$(conf MTU | grep . || echo 1320)" up
		ip -n airvpn -4 route add default dev airvpn
		ip -n airvpn -6 route add default dev airvpn

		# airvpn's resolvers, inside the tunnel
		conf DNS | tr , '\n' | sed 's/^/nameserver /' >${run}/resolv.conf
		chmod 644 ${run}/resolv.conf

		# the account's forwarded port, for transmission to listen on
		jq -n --rawfile p "$CREDENTIALS_DIRECTORY/port" \
			'{"peer-port": ($p | gsub("\\s"; "") | tonumber)}' >${run}/transmission.json

		connect
	'';

	# another server without tearing the namespace down: only the peer's
	# endpoint changes, so transmission keeps running and reconnects
	switch = pkgs.writeShellScript "airvpn-switch" ''
		${common}
		${refresh}
		connect
	'';

	tools = with pkgs; [ iproute2 iputils wireguard-tools jq curl coreutils gnused gnugrep ];
in {
	# the device's wg-quick config from airvpn's client area (config
	# generator, wireguard, any server): its keys and tunnel addresses
	crypt.secrets.airvpn.text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0DcTNTiSAYU3WDXhDHXHbFFGLnk
		5w3CCjk19tAa+jYIDzB4lKGf9yD9vEIafhYWaXF938fbRMYfgHYdlAKAPiU010t+
		PTZDeBr//k+nTdGNKQPBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQCD9HlPL
		gluhaPRvjAgcr15G1m4Lcp4CoJQdcwFb2WdFMOWSjDgBem9xCN2Rueyyc4ccLutW
		m16uvstl1eV7Gsmq4t6a4MlYnshdU6AINP8b4NLBJgIJAgYKASGvyKcj6QgGeror
		D6DXg/RMRYLAP26mLZCUEa5YooZFTfXtMex9l0Pik55fELlBTm+BxQovUGpaF46r
		ZRDZE3HRaUmPlGXpdCWll0a3d4JCBncFd7As4tvS8DzCUrNrfVqvxRuYabeEqvvj
		q47VNNnhklFR7ot3OopNM/qXHomUoEifgmU9sDH8fRPG5lP0YccV/XielC1OFTBh
		WH6BW5zJ3QVW2D7JCT5DgSRoZckWTXnXnAekXNUN3FlJB7ON/ZZaKLFg8jLGUekH
		ZRqgu3nqIjhwxiQbru09/aXDhbwRZIWhe9b5ZZ81doUTxE917XKUuPjzitzBSVfo
		8xiPcYAaa/f+FFx+bO4c4ZtcE+87yopeU5RuJtu8IU9KoCLz61PXvPOt4esgnlCr
		QCRqypqWn/EAC2xxyYd9UvbWr65IZ+4L1Wl33EOZXdF1UUV9ZhcqKTxKF26Ymvis
		jGRPuLFcZCouEEbMyusBPautaigREBT31SxvVBuAo7rsZ8JFcAts5h/iTgM0z1R5
		06FYvjMLtbyPCY53V97yOWcbvovGstSVzKqLHlC1liL3j4nRCKB11ofvUqdY4zKs
		p+u6Btj9FNmJM8WbuhIZ1eLsQHl+kiC5oQmbNsIK2aeScRAUWw==
		-----END PGP MESSAGE-----
	'';
	# the port forwarded to the account (client area, ports), as a number.
	# it's airvpn's on every server, so it would link this repo to the account
	crypt.secrets.airvpn-port.text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0AT3K7K+hPZJGzfiYATlYzLSSK0
		+wgV75hUN4Y01nAeVjCiE6+ooO+PSOIirfijK+xmAufUSX9pOVe5A0h6miQToiAM
		m9OVOm+7Qp7PXt3Gp63BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQEdrazHd
		Y9ysxcUBu85TDksutB/GIsOY/dqEzAfLxPA2MDX7jFOjBe6BMItTgebNR3IRAy9t
		E+wVSlau3qzagtHf4K33iV/H50i5KJqU4E4ZDtJUAgkCBoIYkk/2Of4tAxbVKn2J
		pMyx951Z7o7R4cRn2VSDyWLLX8g+0c8uu7W2fD3DLt5aEw67LK6Z2Z1a3VL8rsYj
		2YeD/q/msZLiJKOvE4UgKfg0
		-----END PGP MESSAGE-----
	'';

	systemd.services.airvpn = {
		description = "network namespace that only reaches the internet through airvpn";
		wants = [ "network-online.target" ];
		after = [ "network-online.target" ];
		path = tools;
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
			StateDirectory = "airvpn";
			LoadCredential = [
				"conf:${config.crypt.secrets.airvpn.path}"
				"port:${config.crypt.secrets.airvpn-port.path}"
			];
			ExecStart = up;
			ExecStop = "${pkgs.iproute2}/bin/ip netns delete airvpn";
			Restart = "on-failure";
			RestartSec = "1min";
		};
	};
	# `systemctl start airvpn-switch` after editing /var/lib/airvpn/prefer,
	# or to move on from a server
	systemd.services.airvpn-switch = {
		description = "switch airvpn servers";
		requisite = [ "airvpn.service" ];
		after = [ "airvpn.service" ];
		path = tools;
		serviceConfig = {
			Type = "oneshot";
			LoadCredential = [ "conf:${config.crypt.secrets.airvpn.path}" ];
			ExecStart = switch;
		};
	};

	services.transmission = {
		enable = true;
		credentialsFile = "${run}/transmission.json";
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
			# the peer port is airvpn's forwarded one (credentialsFile), so
			# peers reach us through it; upnp is for home routers
			port-forwarding-enabled = false;
			peer-port-random-on-start = false;
			encryption = 1; # prefer encrypted peers
		};
	};

	systemd.services.transmission = {
		unitConfig.RequiresMountsFor = [ "/srv/seed" "/srv/seed/video" ];
		bindsTo = [ "airvpn.service" ];
		after = [ "airvpn.service" ];
		serviceConfig = {
			NetworkNamespacePath = netns;
			# joining a namespace the host's user namespace owns needs
			# privileges a private user namespace wouldn't have
			PrivateUsers = false;
			# names resolve through airvpn's resolvers, not the host's: glibc
			# loses nscd (and resolved behind it) and reads the stub's file,
			# which is airvpn's here
			InaccessiblePaths = [ "-/run/nscd" "-/run/systemd/resolve/io.systemd.Resolve" ];
			BindReadOnlyPaths = [ "${run}/resolv.conf:/run/systemd/resolve/stub-resolv.conf" ];
		};
	};

	# the web ui and rpc, carried out of the namespace: the socket is the
	# host's, the proxy connects from inside. on loopback for caddy, and on
	# lemma0's vpn addresses for apps like tremotesf, which can't get past
	# authelia: there the wireguard key is the login. those addresses come
	# with wg-portal's interfaces, so binding mustn't wait for them
	systemd.sockets.transmission-rpc = {
		wantedBy = [ "sockets.target" ];
		listenStreams = [ "127.0.0.1:${toString proxy}" ]
			++ config.vpn.roles.torrent.listen proxy
			++ config.vpn.roles.admin.listen proxy;
		socketConfig.FreeBind = true;
	};
	systemd.services.transmission-rpc = {
		# stopped with the socket: a socket won't start while its service
		# runs, so a changed socket (new addresses) would fail on switch
		partOf = [ "transmission-rpc.socket" ];
		requires = [ "transmission.service" ];
		bindsTo = [ "airvpn.service" ];
		after = [ "transmission.service" "airvpn.service" ];
		serviceConfig = {
			ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString rpc}";
			NetworkNamespacePath = netns;
			DynamicUser = true;
		};
	};

	# who may: members of `torrent`, added in lldap's ui
	lldap.groups = [ "torrent" ];
	# and from their own devices, over the vpn, the rpc and nothing else
	vpn.roles.torrent = {
		n = 2;
		group = "torrent";
		label = "torrent";
		tcp = [ proxy ];
	};
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
		reverse_proxy 127.0.0.1:${toString proxy}
	'';
}
