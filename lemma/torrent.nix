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

	# a namespace with nothing but loopback and the tunnel: when mullvad is
	# down there is no route at all, so nothing leaks around it. the tunnel's
	# udp socket stays outside, since the interface is made there and moved in
	up = pkgs.writeShellScript "mullvad-up" ''
		set -euo pipefail
		conf=$CREDENTIALS_DIRECTORY/mullvad.conf
		# wg-quick's own keys, which wg setconf doesn't take
		field() {
			awk -F= -v k="$1" 'tolower($1) ~ "^[ \t]*" k "[ \t]*$" { print $2 }' "$conf" |
				tr ', \t' '\n' | grep .
		}

		ip netns delete mullvad 2>/dev/null || true
		ip link delete mullvad 2>/dev/null || true
		ip netns add mullvad
		ip -n mullvad link set lo up

		ip link add mullvad type wireguard
		wg setconf mullvad <(wg-quick strip "$conf")
		ip link set mullvad netns mullvad
		for a in $(field address); do ip -n mullvad address add "$a" dev mullvad; done
		ip -n mullvad link set mullvad up
		ip -n mullvad -4 route add default dev mullvad
		ip -n mullvad -6 route add default dev mullvad

		# mullvad's resolver, inside the tunnel
		install -d -m 755 /run/mullvad
		field dns | sed 's/^/nameserver /' >/run/mullvad/resolv.conf
	'';
in {
	crypt.secrets.mullvad.text = todo "mullvad" ''
		mullvad.net/account → WireGuard configuration: generate a key, pick a
		server, and download its wg-quick .conf. the whole file is the secret'';

	systemd.services.mullvad = {
		description = "network namespace that only reaches the internet through mullvad";
		wants = [ "network-online.target" ];
		after = [ "network-online.target" ];
		path = with pkgs; [ iproute2 wireguard-tools gawk gnugrep gnused coreutils ];
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
			LoadCredential = [ "mullvad.conf:${config.crypt.secrets.mullvad.path}" ];
			ExecStart = up;
			ExecStop = "${pkgs.iproute2}/bin/ip netns delete mullvad";
		};
	};
	crypt.secrets.mullvad.services = [ "mullvad" ];

	services.transmission = {
		enable = true;
		package = pkgs.transmission_4;
		settings = {
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
