{ config, lib, ... }: let
	mx = "mx.amartia.online";
	baseDN = "dc=amartia,dc=online";

	# stalwart reads these through LoadCredential; %{file:…}% doesn't trim,
	# so its secrets must not end in a newline
	cred = name: "%{file:/run/credentials/stalwart.service/${name}}%";

	# caddy obtains mx's certificate; stalwart reuses it
	certDir = "${config.services.caddy.dataDir}/.local/share/caddy/"
		+ "certificates/acme-v02.api.letsencrypt.org-directory/${mx}";

	# extra local parts at amartia.online, delivered to and sendable by their
	# account. kept here rather than in lldap: lldap 0.6 can't filter on list
	# attributes, so stalwart couldn't look an alias up there
	aliases = {
		lux = [ "dilux" "rea" "gaia" ];
	};
	aliasesOf = locals:  # with an optional +tag, like any other address
		"^(${lib.concatStringsSep "|" locals})(\\+[^@]*)?@amartia\\.online$";

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';
in {
	crypt.secrets = {
		# sha512-crypt hash of the fallback admin's password (web admin)
		stalwart-admin.text = todo "stalwart-admin"
			"openssl passwd -6 | tr -d '\\n'";
		# password of lldap's read-only `stalwart` account
		stalwart-ldap.text = todo "stalwart-ldap"
			"openssl rand -base64 33 | tr -d '\\n'";
	};

	services.stalwart = {
		enable = true;
		stateVersion = "26.05";
		credentials = {
			admin = config.crypt.secrets.stalwart-admin.path;
			ldap = config.crypt.secrets.stalwart-ldap.path;
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

			certificate.mx = {
				cert = cred "tls-cert";
				private-key = cred "tls-key";
				default = true;
			};
			authentication.fallback-admin = {
				user = "admin";
				secret = cred "admin";
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
					dn = "uid=stalwart,ou=people,${baseDN}";
					secret = cred "ldap";
					auth.method = "lookup";
				};
				filter = {
					name = "(&(objectClass=person)(uid=?))";
					email = "(&(objectClass=person)(mail=?))";
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
			session.rcpt.catch-all = lib.mapAttrsToList (user: locals: {
				"if" = "matches('${aliasesOf locals}', address)";
				"then" = "'${user}@amartia.online'";
			}) aliases ++ [
				{
					"if" = "matches('^[^@]+@cpli\\.dev$', address)";
					"then" = "'cpli@cpli.dev'";
				}
				{ "else" = false; }
			];
			session.rcpt.sub-addressing = true;

			# and each account may send as its aliases, cpli as all of cpli.dev
			session.auth.must-match-sender = lib.mapAttrsToList (user: locals: {
				"if" = "authenticated_as == '${user}' "
					+ "&& matches('${aliasesOf locals}', sender)";
				"then" = false;
			}) aliases ++ [
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
	systemd.services.stalwart.after = [ "lldap.service" "caddy.service" ];
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
		reverse_proxy 127.0.0.1:8080
	'';
}
