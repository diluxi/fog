{ config, lib, ... }: let
	mx = "mx.amartia.online";
	baseDN = "dc=amartia,dc=online";

	# stalwart reads these through LoadCredential; %{file:…}% doesn't trim,
	# so its secrets must not end in a newline
	cred = name: "%{file:/run/credentials/stalwart.service/${name}}%";

	# caddy obtains mx's certificate; stalwart reuses it
	certDir = "${config.services.caddy.dataDir}/.local/share/caddy/"
		+ "certificates/acme-v02.api.letsencrypt.org-directory/${mx}";

	# extra addresses per account: delivered to it, and it may send as them.
	# kept here rather than in lldap: lldap 0.6 can't filter on list
	# attributes, so stalwart couldn't look an alias up there
	accounts = {
		lux = {
			address = "lux@amartia.online";
			aliases = map (local: "${local}@amartia.online")
				[ "dilux" "rea" "gaia" "root" "postmaster" "abuse" ];
		};
		cpli = {
			address = "cpli@cpli.dev";
			aliases = [ "cpli@amartia.online" ];
		};
	};
	# a regex for any of these addresses, each with an optional +tag
	anyOf = addresses: let
		escape = lib.replaceStrings [ "." ] [ "\\." ];
		one = address: let at = lib.splitString "@" address; in
			"${escape (lib.head at)}(\\+[^@]*)?@${escape (lib.last at)}";
	in "^(${lib.concatMapStringsSep "|" one addresses})$";

	# lldap accounts that are services, not people: no mailbox, no login
	notService = lib.concatMapStrings (uid: "(!(uid=${uid}))")
		([ "root" ] ++ lib.attrNames config.lldap.serviceAccounts);

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';
in {
	crypt.secrets = {
		# sha512-crypt hash of the password of stalwart's own root (web admin)
		stalwart-root.services = [ "stalwart" ];
		stalwart-root.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0CUnT8RoQGQwJ+3IiIO5ohnjpzL
			/g4xCY5WRhmyI7AafzD2rwDSdbsS7wOr0ekEdy+Op4NOBtXRKopaCby258C7fAS0
			qF6ONfRV1WF6JyjRnIrBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQBLAptuy
			dQuf5RubxBQVU822wgx1Lby2Kg6ir5DIXg1gMJ1N34HnTzimgF27admua2iJ4QeB
			QILmBiODL7JV3ub2DBhWxZSixq4BrhYnYNS2ZtK+AgkCBqESWsF9UIxJcUHT7Kav
			evjL1ekc0S2lL8TNVSZtKPe3MKd9jrz21OdBPmiKijHC/cnVIthMKMnGbHTJOIBv
			hk3qiuOHZEHjpsjabd0fd1N5o4QuGsPDmkRcDAFfJalGsHp+tPR/oGtAWHXEjo3b
			S0M6oRJcck170OOCg/3uAU0TRMxZKIB3EC+0iKT8mfFLBPDpwVkA9h43dGEkycs0
			dzuo/bUZIOzfceCfZT/+ZRXvG3pTQpdD1/R1MA==
			-----END PGP MESSAGE-----
		'';
	};

	services.stalwart = {
		enable = true;
		stateVersion = "26.05";
		credentials = {
			root = config.crypt.secrets.stalwart-root.path;
			ldap = config.lldap.serviceAccounts.stalwart.passwordFile;
			tls-cert = "${certDir}/${mx}.crt";
			tls-key = "${certDir}/${mx}.key";
		};
		settings = {
			# keys this file owns: stalwart's defaults, plus what is set here
			# (or by the nixos module) that it would otherwise keep in its db
			config.local-keys = [
				"store.*" "directory.*" "tracer.*"
				"!server.blocked-ip.*" "!server.allowed-ip.*" "server.*"
				"certificate.*" "config.local-keys.*"
				"authentication.fallback-admin.*" "cluster.*"
				"storage.data" "storage.blob" "storage.lookup" "storage.fts"
				"storage.directory" "enterprise.license-key"
				"session.rcpt.catch-all.*" "session.rcpt.sub-addressing"
				"session.auth.must-match-sender.*" "http.use-x-forwarded"
				"spam-filter.resource" "resolver.*" "webadmin.*"
				"metrics.prometheus.*"
			];

			server.hostname = mx;
			server.listener = {
				smtp = { bind = [ "[::]:25" ]; protocol = "smtp"; };
				submission = { bind = [ "[::]:587" ]; protocol = "smtp"; };
				submissions = {
					bind = [ "[::]:465" ];
					protocol = "smtp";
					tls.implicit = true;
				};
				imaps = {
					bind = [ "[::]:993" ];
					protocol = "imap";
					tls.implicit = true;
				};
				# web admin, jmap and account pages, behind caddy
				http = { bind = [ "127.0.0.1:8080" ]; protocol = "http"; };
			};
			http.use-x-forwarded = true;
			# for prometheus (lemma/pulse.nix); caddy keeps it off the web
			metrics.prometheus.enable = true;

			certificate.mx = {
				cert = cred "tls-cert";
				private-key = cred "tls-key";
				default = true;
			};
			# local to stalwart, for when lldap is down
			authentication.fallback-admin = {
				user = "root";
				secret = cred "root";
			};

			# accounts are lldap's users. stalwart searches as `stalwart`
			# (in lldap_strict_readonly) and checks passwords by binding as
			# the user, since lldap never hands out password hashes
			storage.directory = "ldap";
			directory.ldap = {
				type = "ldap";
				url = "ldap://127.0.0.1:3890";
				base-dn = baseDN;
				bind = {
					dn = config.lldap.serviceAccounts.stalwart.dn;
					secret = cred "ldap";
					auth.method = "lookup";
				};
				filter = {
					name = "(&(objectClass=person)(uid=?)${notService})";
					email = "(&(objectClass=person)(mail=?)${notService})";
				};
				attributes = {
					name = "uid";
					class = "objectClass";
					description = "cn";
					email = "mail";
				};
			};

			# unknown recipients: aliases go to their account, everything
			# for cpli.dev to cpli. user+tag@ goes to user@
			session.rcpt.catch-all = lib.mapAttrsToList (uid: account: {
				"if" = "matches('${anyOf account.aliases}', address)";
				"then" = "'${account.address}'";
			}) accounts ++ [
				{
					"if" = "matches('^[^@]+@cpli\\.dev$', address)";
					"then" = "'cpli@cpli.dev'";
				}
				{ "else" = false; }
			];
			session.rcpt.sub-addressing = true;

			# and each account may send as its aliases, cpli as all of cpli.dev
			session.auth.must-match-sender = lib.mapAttrsToList (uid: account: {
				"if" = "authenticated_as == '${uid}' "
					+ "&& matches('${anyOf account.aliases}', sender)";
				"then" = false;
			}) accounts ++ [
				{
					"if" = "authenticated_as == 'cpli' "
						+ "&& matches('@cpli\\.dev$', sender)";
					"then" = false;
				}
				{ "else" = true; }
			];
		};
	};

	networking.firewall.allowedTCPPorts = [ 25 465 587 993 ];

	# a renewed certificate only reaches stalwart through a restart, since
	# LoadCredential copies it at start
	lldap.serviceAccounts.stalwart.groups = [ "lldap_strict_readonly" ];
	systemd.services.stalwart.wants = [ "lldap-accounts.service" ];
	systemd.services.stalwart.after = [ "lldap-accounts.service" "caddy.service" ];
	systemd.paths.stalwart-certificate = {
		wantedBy = [ "multi-user.target" ];
		pathConfig.PathChanged = "${certDir}/${mx}.crt";
	};
	systemd.services.stalwart-certificate = {
		serviceConfig.Type = "oneshot";
		script = "systemctl try-restart stalwart.service";
	};

	services.caddy.virtualHosts.${mx}.extraConfig = ''
		# pin the issuer, so the certificate stays where stalwart looks for it
		tls {
			issuer acme {
				dir https://acme-v02.api.letsencrypt.org/directory
			}
		}
		respond /metrics/* 404
		reverse_proxy 127.0.0.1:8080
	'';

	# thunderbird's (and k-9's) account autoconfig, which stalwart answers
	# with mx's ports and the account's lldap uid. only that path is proxied,
	# so the web admin stays on mx alone
	services.caddy.virtualHosts."autoconfig.amartia.online" = {
		serverAliases = [ "autoconfig.cpli.dev" ];
		extraConfig = ''
			handle /mail/config-v1.1.xml {
				reverse_proxy 127.0.0.1:8080
			}
			handle {
				respond 404
			}
		'';
	};
}
