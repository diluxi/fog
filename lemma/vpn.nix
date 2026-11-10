{ config, lib, pkgs, ... }: let
	cfg = config.vpn;
	domain = "amartia.online";
	host = "vpn.${domain}";
	auth = "auth.${domain}";
	port = 8098;
	ldap = config.services.lldap.settings;
	baseDN = ldap.ldap_base_dn;
	group = name: "cn=${name},ou=groups,${baseDN}";
	member = r: "(memberOf=${group r.group})";
	account = config.lldap.serviceAccounts.wg-portal;
	generated = name: config.crypt.generated.${name}.path;

	wg-portal = pkgs.callPackage ./wg-portal.nix {};

	# lemma0's vpn ranges: a ula prefix of its own (rfc 4193, drawn
	# 2026-11-10) and 10.10/16. role n gets the nth /64 and /24, lemma0 is ::1
	# and .1 in each, and its peers what wg-portal hands out after
	ula = "fd60:d315:194a";
	v4 = r: "10.10.${toString r.n}";
	v6 = r: "${ula}:${lib.toHexString r.n}";

	# secrets nobody types, made on lemma0. wg-portal reads them from the
	# environment, substituted into its config
	secrets = {
		ADMIN_PASSWORD = "wg-portal-admin";
		ADMIN_TOKEN = "wg-portal-token";
		DB_KEY = "wg-portal-db";
		SESSION_SECRET = "wg-portal-session";
		CSRF_SECRET = "wg-portal-csrf";
		OIDC_SECRET = "wg-portal-oidc";
		LDAP_PASSWORD = "lldap-wg-portal";
	};

	# json, which is yaml. ${...} is wg-portal's envsubst
	configFile = pkgs.writeText "wg-portal.yml" (builtins.toJSON {
		core = {
			# the api's account, for wg-portal-roles; nobody logs in as it
			admin_user = "nix";
			admin_password = "\${ADMIN_PASSWORD}";
			admin_api_token = "\${ADMIN_TOKEN}";
			self_provisioning_allowed = true;
			import_existing = false;
			restore_state = true;
		};
		# fog and dn42 are networkd's
		backend.ignored_local_interfaces = [ "fog" "dn42" ];
		advanced.log_level = "info";
		database = {
			type = "sqlite";
			dsn = "/var/lib/wg-portal/sqlite.db";
			# private keys, encrypted where they're stored
			encryption_passphrase = "\${DB_KEY}";
		};
		statistics = {
			use_ping_checks = false;
			listening_address = "127.0.0.1:8787";
		};
		web = {
			listening_address = "127.0.0.1:${toString port}";
			external_url = "https://${host}";
			site_title = "vpn";
			site_company_name = domain;
			session_secret = "\${SESSION_SECRET}";
			csrf_secret = "\${CSRF_SECRET}";
		};
		auth = {
			# logins only through authelia, with a second factor
			hide_login_form = true;
			webauthn.enabled = false;
			oidc = [{
				provider_name = "authelia";
				display_name = domain;
				base_url = "https://${auth}";
				client_id = "wg-portal";
				client_secret = "\${OIDC_SECRET}";
				extra_scopes = [ "profile" "email" "groups" ];
				field_map = {
					user_identifier = "preferred_username";
					email = "email";
					firstname = "name";
					user_groups = "groups";
				};
				admin_mapping.admin_group_regex = "^lldap_admin\\z";
				registration_enabled = true;
				# authelia has no rp-initiated logout
				logout_idp_session = false;
			}];
			# lldap only for who's in which role: the sync creates everyone in
			# one, disables (with their peers) who's in none, and decides which
			# interfaces each may add peers to. nobody logs in through it
			ldap = [{
				provider_name = "lldap";
				url = "ldap://${ldap.ldap_host}:${toString ldap.ldap_port}";
				base_dn = "ou=people,${baseDN}";
				bind_user = account.dn;
				bind_pass = "\${LDAP_PASSWORD}";
				field_map = {
					user_identifier = "uid";
					email = "mail";
					firstname = "givenName";
					lastname = "sn";
					memberof = "memberOf";
				};
				login_filter = "(!(objectClass=*))";
				admin_group = group "lldap_admin";
				sync_interval = "5m";
				sync_filter = "(&(objectClass=person)(|${lib.concatMapStrings member (lib.attrValues cfg.roles)}))";
				disable_missing = true;
				auto_re_enable = true;
				interface_filter = lib.mapAttrs' (_: r: lib.nameValuePair r.interface (member r)) cfg.roles;
			}];
		};
	});

	# each role's interface as wg-portal's api takes it, with the key added at
	# run time. peers reach lemma0's address on it and nothing beyond
	interface = r: {
		Identifier = r.interface;
		DisplayName = r.label;
		Mode = "server";
		Disabled = false;
		ListenPort = r.port;
		Addresses = [ "${v4 r}.1/24" "${v6 r}::1/64" ];
		# the addresses' own routes are all there is
		RoutingTable = "off";
		SaveConfig = false;
		PeerDefNetwork = [ "${v4 r}.0/24" "${v6 r}::/64" ];
		PeerDefEndpoint = "${host}:${toString r.port}";
		PeerDefAllowedIPs = [ "${v4 r}.1/32" "${v6 r}::1/128" ];
	};
in {
	options.vpn.roles = lib.mkOption {
		description = ''
			lemma0's vpn, one wireguard interface per role, which wg-portal
			owns along with its peers. who may add peers to a role is an lldap
			group; what the peers reach is the firewall, by interface.
		'';
		default = {};
		type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
			options = {
				n = lib.mkOption {
					description = "The role's place in the ranges and ports. Unique, and fixed once used.";
					type = lib.types.ints.between 1 255;
				};
				group = lib.mkOption {
					description = "The lldap group whose members may add peers.";
					type = lib.types.str;
				};
				label = lib.mkOption { type = lib.types.str; };
				trusted = lib.mkOption {
					description = "Whether peers reach everything on lemma0.";
					type = lib.types.bool;
					default = false;
				};
				tcp = lib.mkOption {
					description = "TCP ports on lemma0 the peers reach.";
					type = lib.types.listOf lib.types.port;
					default = [];
				};
				interface = lib.mkOption {
					type = lib.types.str;
					default = "fog-${name}";
					readOnly = true;
				};
				port = lib.mkOption {
					type = lib.types.port;
					default = 51820 + config.n;
					readOnly = true;
				};
				listen = lib.mkOption {
					description = "lemma0's addresses on the role's interface, as host:port for a port.";
					type = lib.types.functionTo (lib.types.listOf lib.types.str);
					default = p: [ "${v4 config}.1:${toString p}" "[${v6 config}::1]:${toString p}" ];
					readOnly = true;
				};
			};
		}));
	};

	config = {
		assertions = [
			{
				assertion = lib.allUnique (lib.mapAttrsToList (_: r: r.n) cfg.roles);
				message = "vpn.roles: each role needs its own n";
			}
		] ++ lib.mapAttrsToList (_: r: {
			assertion = lib.stringLength r.interface <= 15;
			message = "vpn.roles: ${r.interface} is longer than an interface name may be";
		}) cfg.roles;

		vpn.roles.admin = {
			n = 1;
			group = "lldap_admin";
			label = "admin";
			trusted = true;
		};

		lldap.serviceAccounts.wg-portal.groups = [ "lldap_strict_readonly" ];

		crypt.generated = {
			wg-portal-admin = {};
			wg-portal-token = {};
			wg-portal-db = {};
			wg-portal-session = {};
			wg-portal-csrf = {};
			# the client secret, with authelia's digest of it beside it
			wg-portal-oidc.script = ''
				${pkgs.authelia}/bin/authelia crypto hash generate pbkdf2 \
					--variant sha512 --random --random.length 64 \
					--random.charset alphanumeric >$out.both
				sed -n 's/^Random Password: //p' $out.both | tr -d '\n' >$out
				sed -n 's/^Digest: //p' $out.both | tr -d '\n' >$out.digest
				rm $out.both
			'';
		} // lib.mapAttrs' (_: r: lib.nameValuePair "vpn-${r.interface}" {
			# the interface's private key, here so a lost database loses peers
			# but not the server key every peer's config names
			script = "${pkgs.wireguard-tools}/bin/wg genkey | tr -d '\\n' >$out";
		}) cfg.roles;

		systemd.services.wg-portal = {
			description = "wireguard peers, added by people in lldap";
			wantedBy = [ "multi-user.target" ];
			wants = [ "network-online.target" "lldap-accounts.service" ];
			after = [ "network-online.target" "lldap-accounts.service" "authelia-main.service" ];
			environment.WG_PORTAL_CONFIG = configFile;
			script = lib.concatStrings (lib.mapAttrsToList (var: _: ''
				${var}=$(<"$CREDENTIALS_DIRECTORY/${var}"); export ${var}
			'') secrets) + ''
				exec ${wg-portal}/bin/wg-portal
			'';
			serviceConfig = {
				LoadCredential = lib.mapAttrsToList (var: name: "${var}:${generated name}") secrets;
				DynamicUser = true;
				StateDirectory = "wg-portal";
				StateDirectoryMode = "0700";
				WorkingDirectory = "/var/lib/wg-portal";
				Restart = "on-failure";
				# making and configuring interfaces
				AmbientCapabilities = [ "CAP_NET_ADMIN" ];
				CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
				RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
				PrivateTmp = true;
				PrivateDevices = true;
				ProtectSystem = "strict";
				ProtectHome = true;
				ProtectKernelModules = true;
				NoNewPrivileges = true;
				LockPersonality = true;
				SystemCallArchitectures = "native";
			};
		};

		# the roles' interfaces, made or brought in line through wg-portal's
		# api: what's declared here wins, the peers are wg-portal's
		systemd.services.wg-portal-roles = {
			description = "wg-portal's interfaces, one per vpn role";
			wantedBy = [ "multi-user.target" ];
			requires = [ "wg-portal.service" ];
			after = [ "wg-portal.service" ];
			partOf = [ "wg-portal.service" ];
			path = with pkgs; [ curl jq wireguard-tools ];
			serviceConfig = {
				Type = "oneshot";
				RemainAfterExit = true;
				DynamicUser = true;
				RuntimeDirectory = "wg-portal-roles";
				RuntimeDirectoryMode = "0700";
				LoadCredential = [ "token:${generated "wg-portal-token"}" ]
					++ lib.mapAttrsToList (_: r: "${r.interface}:${generated "vpn-${r.interface}"}") cfg.roles;
			};
			script = ''
				api=http://127.0.0.1:${toString port}/api/v1/interface
				# the token through a file, not on a command line
				rc=$RUNTIME_DIRECTORY/curlrc
				printf 'user = "nix:%s"\n' "$(<"$CREDENTIALS_DIRECTORY/token")" >"$rc"
				get() { curl -sSf -K "$rc" "$api/$1"; }
				send() { curl -sSf -K "$rc" -X "$1" -H 'content-type: application/json' --data-binary @- "$api/$2" >/dev/null; }

				for i in $(seq 60); do get all >/dev/null 2>&1 && break; sleep 1; done

				role() {
					local id=$1 want=$2 key=$CREDENTIALS_DIRECTORY/$1
					want=$(jq -c --rawfile k "$key" --arg p "$(wg pubkey <"$key")" \
						'. + {PrivateKey: $k, PublicKey: $p}' <<<"$want")
					if have=$(get "by-id/$id" 2>/dev/null); then
						jq -c --argjson w "$want" '. * $w' <<<"$have" | send PUT "by-id/$id"
						echo "$id: brought in line"
					else
						get prepare | jq -c --argjson w "$want" '. * $w' | send POST new
						echo "$id: made"
					fi
				}
			'' + lib.concatMapStrings (r: ''
				role ${r.interface} ${lib.escapeShellArg (builtins.toJSON (interface r))}
			'') (lib.attrValues cfg.roles);
		};

		networking.firewall = {
			allowedUDPPorts = lib.mapAttrsToList (_: r: r.port) cfg.roles;
			trustedInterfaces = lib.mapAttrsToList (_: r: r.interface)
				(lib.filterAttrs (_: r: r.trusted) cfg.roles);
			interfaces = lib.mapAttrs' (_: r: lib.nameValuePair r.interface {
				allowedTCPPorts = r.tcp;
			}) (lib.filterAttrs (_: r: !r.trusted) cfg.roles);
		};

		services.authelia.instances.main.settings.identity_providers.oidc = {
			authorization_policies.vpn = {
				default_policy = "deny";
				rules = [{
					policy = "two_factor";
					subject = lib.mapAttrsToList (_: r: "group:${r.group}") cfg.roles;
				}];
			};
			clients = [{
				client_id = "wg-portal";
				client_name = "vpn";
				client_secret = ''{{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/wg-portal-oidc-digest" | secret }}'';
				authorization_policy = "vpn";
				require_pkce = true;
				pkce_challenge_method = "S256";
				redirect_uris = [ "https://${host}/api/v0/auth/login/authelia/callback" ];
				scopes = [ "openid" "profile" "email" "groups" ];
				token_endpoint_auth_method = "client_secret_basic";
			}];
		};
		systemd.services.authelia-main.serviceConfig.LoadCredential = [
			"wg-portal-oidc-digest:${generated "wg-portal-oidc"}.digest"
		];

		# the v1 api is for wg-portal-roles, over loopback. password logins,
		# which the hidden form would still take for nix, aren't for anyone
		services.caddy.virtualHosts.${host}.extraConfig = ''
			@api path /api/v1 /api/v1/*
			respond @api 404
			@password path /api/v0/auth/login /api/v0/auth/webauthn/*
			respond @password 404
			reverse_proxy 127.0.0.1:${toString port}
		'';
	};
}
