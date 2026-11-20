{ config, lib, pkgs, ... }: let
	# qbittorrent's interface (qui) and prowlarr, one host: qui at its
	# root, prowlarr under /prowlarr
	seed = "seed.amartia.online";
	auth = "auth.amartia.online";
	netns = "/run/netns/airvpn";
	# qbittorrent's web api inside the namespace, and its proxy outside it,
	# for qui and the vpn (authelia has 9091). one port: qbittorrent refuses
	# a request whose host header names a port other than its own
	webui = 9092;
	proxy = webui;
	quiPort = 7476;

	# a directory under /srv/seed per kind, each a category of qbittorrent's
	# that saves there. video is what kino links, manga, comics and books
	# what the shelf links (lemma/box.nix, lemma/odos.nix)
	kinds = [ "video" "audio" "books" "comics" "manga" "other" ];
	qbittorrentConfig = "/var/lib/qBittorrent/qBittorrent/config";

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
				# the handshake below is the new server's. and a new port of our
				# own: every airvpn server has the same key, so a server we left
				# that still has traffic for us would start a handshake to our
				# address, wireguard would follow it there, and the tunnel would
				# flip between servers. it can't reach a port we no longer use
				ip netns exec airvpn wg set airvpn listen-port 0
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

		# the account's forwarded port, for qbittorrent to listen on
		tr -d '[:space:]' <"$CREDENTIALS_DIRECTORY/port" >${run}/port

		connect
	'';

	# another server without tearing the namespace down: only the peer's
	# endpoint changes, so qbittorrent keeps running and reconnects
	switch = pkgs.writeShellScript "airvpn-switch" ''
		${common}
		${refresh}
		connect
	'';

	# what a service needs to live inside the namespace: joining a namespace
	# the host's user namespace owns needs privileges a private user
	# namespace wouldn't have, and names resolve through airvpn's resolvers,
	# not the host's: glibc loses nscd (and resolved behind it) and reads the
	# stub's file, which is airvpn's here
	inside = {
		NetworkNamespacePath = netns;
		PrivateUsers = false;
		InaccessiblePaths = [ "-/run/nscd" "-/run/systemd/resolve/io.systemd.Resolve" ];
		BindReadOnlyPaths = [ "${run}/resolv.conf:/run/systemd/resolve/stub-resolv.conf" ];
	};

	# prowlarr, the indexers' search, inside too: trackers see one address
	# for searching and announcing, and it hands torrents to qbittorrent
	# at 127.0.0.1:${toString webui} there
	prowlarrBase = "/prowlarr";
	prowlarrPort = 9696; # inside the namespace
	prowlarrProxy = 9697; # outside it, for caddy, the vpn and whatever searches through it

	tools = with pkgs; [ iproute2 iputils wireguard-tools jq curl coreutils gnused gnugrep ];

	# after the module has put qBittorrent.conf in place: the forwarded port
	# in it, and the categories, declared ones over what the ui added
	qbittorrentPrepare = pkgs.writeShellScript "qbittorrent-prepare" ''
		set -euo pipefail
		dir=${qbittorrentConfig}
		${pkgs.gnused}/bin/sed -i "s/@port@/$(cat ${run}/port)/" $dir/qBittorrent.conf
		[ -s $dir/categories.json ] || echo '{}' >$dir/categories.json
		${pkgs.jq}/bin/jq --argjson want ${lib.escapeShellArg (builtins.toJSON
			(lib.genAttrs kinds (kind: { save_path = "/srv/seed/${kind}"; })))} \
			'. * $want' $dir/categories.json >$dir/categories.json.new
		mv $dir/categories.json.new $dir/categories.json
	'';

	# qui's client secret, made on lemma0 with its pbkdf2 digest beside it:
	# qui reads the secret, authelia only the digest
	quiOidc = config.crypt.generated.qui-oidc.path;
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

	services.qbittorrent = {
		enable = true;
		webuiPort = webui;
		serverConfig = {
			# qbittorrent-nox asks for this on a terminal otherwise
			LegalNotice.Accepted = true;
			BitTorrent.Session = {
				# pread and pwrite, not mmap: libtorrent's default maps files,
				# which over gocryptfs and smb stalls whatever touches them. and
				# not "posix" either, libtorrent's single-threaded backend, which
				# reads and writes in its network thread, so every 23 ms read
				# from witness0 held up every connection: one ceiling near 20
				# mbit for all torrents together. this is the threaded backend
				# with mmap turned off, so the threads below apply
				DiskIOType = "SimplePreadPwrite";
				# and many at once: a read from witness0 takes some 23 ms, so
				# throughput is concurrency (fio, 16k random reads: 0.7 MiB/s
				# with one, 17 with ten, qbittorrent's default, 65 with 32)
				AsyncIOThreadsCount = 32;
				# everything goes to witness0 (lemma/box.nix), partial torrents
				# too, so qbittorrent can't fill lemma0's own disk, which every
				# other service's databases live on; by category, else other/
				DefaultSavePath = "/srv/seed/other";
				TempPathEnabled = false;
				# and nothing reserved ahead: files grow as pieces come in
				Preallocation = false;
				# a torrent goes where its category says, and moves with it
				DisableAutoTMMByDefault = false;
				DisableAutoTMMTriggers = {
					CategoryChanged = false;
					CategorySavePathChanged = false;
				};
				# airvpn's forwarded port (qbittorrentPrepare), so peers reach us
				Port = "@port@";
				# every torrent active at once. off is qbittorrent's default only
				# for a first run; a config written before its first start reads
				# to it as an old install's, which gets queueing on, three
				# torrents seeding and the rest queued
				QueueingSystemEnabled = false;
			};
			# upnp and nat-pmp are for home routers
			Network.PortForwardingEnabled = false;
			# only what reaches its loopback, where the proxy connects from:
			# qui, and the vpn, where the wireguard key is the login
			WebUI = {
				Address = "127.0.0.1";
				LocalHostAuth = false;
			};
		};
	};

	systemd.services.qbittorrent = {
		# restarted on a switch once the new units are loaded, not stopped
		# before and started after: in between, a request on its proxy's
		# socket (qui polls) would start it from the old unit, with the old
		# config, and the switch would find it running and leave it
		stopIfChanged = false;
		unitConfig.RequiresMountsFor = [ "/srv/seed" ] ++ map (kind: "/srv/seed/${kind}") [ "video" "manga" "comics" "books" ];
		bindsTo = [ "airvpn.service" ];
		after = [ "airvpn.service" ];
		serviceConfig = inside // {
			# the module's sandbox has a user namespace of its own, which can't
			# join airvpn's network namespace
			PrivateUsers = lib.mkForce false;
			ExecStartPre = lib.mkAfter [ qbittorrentPrepare ];
		};
	};

	# its web api, carried out of the namespace: the socket is the host's,
	# the proxy connects from inside, so qbittorrent sees loopback. for qui
	# on lemma0's loopback, and on lemma0's vpn addresses for apps, where
	# the wireguard key is the login. those addresses come with wg-portal's
	# interfaces, so binding mustn't wait for them
	systemd.sockets.qbittorrent-proxy = {
		wantedBy = [ "sockets.target" ];
		listenStreams = [ "127.0.0.1:${toString proxy}" ]
			++ config.vpn.roles.torrent.listen proxy
			++ config.vpn.roles.admin.listen proxy;
		socketConfig.FreeBind = true;
	};
	systemd.services.qbittorrent-proxy = {
		# stopped with the socket: a socket won't start while its service
		# runs, so a changed socket (new addresses) would fail on switch
		partOf = [ "qbittorrent-proxy.socket" ];
		requires = [ "qbittorrent.service" ];
		bindsTo = [ "airvpn.service" ];
		after = [ "qbittorrent.service" "airvpn.service" ];
		serviceConfig = {
			ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString webui}";
			NetworkNamespacePath = netns;
			DynamicUser = true;
		};
	};

	# qui, qbittorrent's interface, on the host: it only talks to the
	# proxy. logins through authelia, for torrent with a second factor; qui
	# has one account, and any login authelia lets through is it
	services.qui = {
		enable = true;
		secretFile = config.crypt.generated.qui-session.path;
		settings = {
			host = "127.0.0.1";
			port = quiPort;
			oidcEnabled = true;
			oidcIssuer = "https://${auth}";
			oidcClientId = "qui";
			oidcRedirectUrl = "https://${seed}/api/auth/oidc/callback";
			oidcDisableBuiltInLogin = true;
			sessionCookieSecure = true;
			# nothing from the host to trackers' sites or to qui's makers
			trackerIconsFetchEnabled = false;
			checkForUpdates = false;
			disableSelfUpdate = true;
		};
	};
	systemd.services.qui.serviceConfig = {
		LoadCredential = [ "oidc:${quiOidc}" ];
		Environment = [ "QUI__OIDC_CLIENT_SECRET_FILE=%d/oidc" ];
	};
	crypt.generated = {
		qui-session = {};
		qui-oidc.script = ''
			${pkgs.authelia}/bin/authelia crypto hash generate pbkdf2 \
				--variant sha512 --random --random.length 64 \
				--random.charset alphanumeric >$out.both
			sed -n 's/^Random Password: //p' $out.both | tr -d '\n' >$out
			sed -n 's/^Digest: //p' $out.both | tr -d '\n' >$out.digest
			rm $out.both
		'';
	};
	services.authelia.instances.main.settings.identity_providers.oidc = {
		authorization_policies.seed = {
			default_policy = "deny";
			rules = [{ policy = "two_factor"; subject = "group:torrent"; }];
		};
		clients = [{
			client_id = "qui";
			client_name = "seed";
			# the template filter (on for the oidc key) reads the digest
			client_secret = ''{{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/qui-oidc-digest" | secret }}'';
			authorization_policy = "seed";
			require_pkce = true;
			pkce_challenge_method = "S256";
			redirect_uris = [ "https://${seed}/api/auth/oidc/callback" ];
			scopes = [ "openid" "profile" "email" ];
			grant_types = [ "authorization_code" ];
			response_types = [ "code" ];
			token_endpoint_auth_method = "client_secret_basic";
		}];
	};
	systemd.services.authelia-main.serviceConfig.LoadCredential = [
		"qui-oidc-digest:${quiOidc}.digest"
	];

	# who may: members of `torrent`, added in lldap's ui
	lldap.groups = [ "torrent" ];
	# and from their own devices, over the vpn, qbittorrent's api and
	# prowlarr, and nothing else
	vpn.roles.torrent = {
		n = 2;
		group = "torrent";
		label = "torrent";
		tcp = [ proxy prowlarrProxy ];
	};
	invite.groups.torrent = {
		label = "Torrents";
		info = "https://${seed}, after a second factor you set up on first login; or over the vpn, from a device you add at https://vpn.amartia.online";
	};
	services.authelia.instances.main.settings.access_control.rules = [
		{ domain = seed; subject = [ "group:torrent" ]; policy = "two_factor"; }
	];

	# qui at the root, logging in through authelia itself; prowlarr behind
	# authelia's forward_auth. prowlarr's polling without any authelia
	# session (a tab from before a login) gets a 401 from caddy, without
	# asking authelia, which would log every one
	services.caddy.virtualHosts.${seed}.extraConfig = ''
		@anonymous {
			path ${prowlarrBase}/api/* ${prowlarrBase}/signalr/*
			not header Cookie *authelia_session=*
		}
		handle @anonymous {
			respond 401
		}
		@prowlarr path ${prowlarrBase} ${prowlarrBase}/*
		handle @prowlarr {
			forward_auth 127.0.0.1:9091 {
				uri /api/authz/forward-auth
				copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
			}
			reverse_proxy 127.0.0.1:${toString prowlarrProxy}
		}
		handle {
			reverse_proxy 127.0.0.1:${toString quiPort}
		}
	'';

	services.prowlarr = {
		enable = true;
		settings = {
			server = {
				bindaddress = "127.0.0.1";
				port = prowlarrPort;
				urlbase = prowlarrBase;
			};
			# authelia stands in front
			auth = { method = "External"; required = "DisabledForLocalAddresses"; };
		};
		# its api key, made on lemma0, for what searches through it
		environmentFiles = [ config.crypt.generated.prowlarr-api.path ];
	};
	crypt.generated.prowlarr-api.script = ''
		printf 'PROWLARR__AUTH__APIKEY=%s\n' "$(openssl rand -hex 16)" >$out
	'';
	systemd.services.prowlarr = {
		# as qbittorrent: its proxy's socket would start the old unit mid-switch
		stopIfChanged = false;
		bindsTo = [ "airvpn.service" ];
		after = [ "airvpn.service" ];
		serviceConfig = inside;
	};

	# qbittorrent as its download client, for what's grabbed from its own
	# searches. a category is qbittorrent's, which saves to a directory under
	# /srv/seed, by what the indexer says a release is (newznab's numbers,
	# with their subcategories); anything else goes to other/. transmission,
	# its client before, goes
	systemd.services.prowlarr-clients = let
		kinds = [
			{ clientCategory = "video"; categories = [ 2000 5000 ]; } # films, tv
			{ clientCategory = "audio"; categories = [ 3000 ]; }
			{ clientCategory = "books"; categories = [ 7000 ]; }
		];
		fields = {
			host = "127.0.0.1";
			port = webui;
			category = "other";
		};
	in {
		description = "prowlarr's download client, qbittorrent";
		wantedBy = [ "multi-user.target" ];
		requires = [ "prowlarr-proxy.socket" ];
		# saving it tests it, so qbittorrent must answer
		wants = [ "qbittorrent.service" ];
		after = [ "prowlarr-proxy.socket" "qbittorrent.service" ];
		partOf = [ "prowlarr.service" ];
		path = with pkgs; [ curl jq ];
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
			DynamicUser = true;
			RuntimeDirectory = "prowlarr-clients";
			RuntimeDirectoryMode = "0700";
			LoadCredential = [ "api:${config.crypt.generated.prowlarr-api.path}" ];
			Restart = "on-failure";
			RestartSec = "30s";
		};
		script = ''
			api=http://127.0.0.1:${toString prowlarrProxy}${prowlarrBase}/api/v1
			# the key through a file, not on a command line
			rc=$RUNTIME_DIRECTORY/curlrc
			printf 'header = "X-Api-Key: %s"\n' \
				"$(sed -n 's/^PROWLARR__AUTH__APIKEY=//p' "$CREDENTIALS_DIRECTORY/api")" >"$rc"
			get() { curl -sSf -K "$rc" "$api/$1"; }
			send() { curl -sSf -K "$rc" -X "$1" -H 'content-type: application/json' --data-binary @- "$api/$2" >/dev/null; }

			for i in $(seq 120); do get system/status >/dev/null 2>&1 && break; sleep 1; done
			# and qbittorrent: saving the client makes prowlarr test it, and a
			# switch restarts both at once
			for i in $(seq 120); do
				curl -sf http://127.0.0.1:${toString proxy}/api/v2/app/version >/dev/null && break
				sleep 1
			done

			# prowlarr's own schema, with what's declared here filled in
			want=$(get downloadclient/schema | jq -c \
				--argjson fields ${lib.escapeShellArg (builtins.toJSON fields)} \
				--argjson kinds ${lib.escapeShellArg (builtins.toJSON kinds)} '
				.[] | select(.implementation == "QBittorrent")
				| .name = "qBittorrent" | .enable = true | .categories = $kinds
				| .fields |= map((.name // "") as $n
					| if $fields | has($n) then .value = $fields[$n] else . end)')
			old=$(get downloadclient | jq '.[] | select(.name == "Transmission") | .id')
			[ -z "$old" ] || curl -sSf -K "$rc" -X DELETE "$api/downloadclient/$old" >/dev/null
			id=$(get downloadclient | jq '.[] | select(.name == "qBittorrent") | .id')
			if [ -n "$id" ]; then
				jq --argjson id "$id" '.id = $id' <<<"$want" | send PUT "downloadclient/$id"
			else
				send POST downloadclient <<<"$want"
			fi
		'';
	};

	# its web ui and api, carried out of the namespace like qbittorrent's,
	# to the same places: on the vpn its own login is off too, and the
	# wireguard key is the login
	systemd.sockets.prowlarr-proxy = {
		wantedBy = [ "sockets.target" ];
		listenStreams = [ "127.0.0.1:${toString prowlarrProxy}" ]
			++ config.vpn.roles.torrent.listen prowlarrProxy
			++ config.vpn.roles.admin.listen prowlarrProxy;
		socketConfig.FreeBind = true;
	};
	systemd.services.prowlarr-proxy = {
		# stopped with the socket, as qbittorrent-proxy is
		partOf = [ "prowlarr-proxy.socket" ];
		requires = [ "prowlarr.service" ];
		bindsTo = [ "airvpn.service" ];
		after = [ "prowlarr.service" "airvpn.service" ];
		serviceConfig = {
			ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString prowlarrPort}";
			NetworkNamespacePath = netns;
			DynamicUser = true;
		};
	};
}
