{ config, ... }: let
	domain = "amartia.online";
	baseDN = "dc=amartia,dc=online";
	auth = "auth.${domain}";
	ldap = "ldap.${domain}";

	# secrets reach both services through LoadCredential, so they stay
	# root-owned in /run/crypt; lldap's DynamicUser doesn't exist at activation
	secret = name: config.crypt.secrets.${name}.path;

	# internals made on lemma0 (crypt.generated), in /var/lib/crypt
	generated = name: config.crypt.generated.${name}.path;
in {
	crypt.secrets = {
		# key_seed derives lldap's password-hashing key. losing it voids every
		# stored password, so it lives here rather than only in /var/lib
		lldap-env.services = [ "lldap" ];
		lldap-env.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0Dje55fOZf9Hq1eEf5UtNJZuQBb
			nGMbpB+8fi6c5P9xEDDfMt4/vu0jO1NQgl6mT06I+uWf8YjZdSSaIER8XXzylOLx
			OVBm9oQ8UpZYOVl+tb/BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQOX2vGy4
			M5rNirgcIcTve3NrRotN72Rndr9F5SYrsgwOMNXH6Igqv/mHR2yl9vK4meiU8pg+
			2CMUjDpsoVzE4heVYD+cAjgSPlRmx5cIVlJr4tKeAgkCBmNYHj5jJjCnGKoGvEkE
			b9c7xWMaSieU8mwaTlQ7VipgRuQDo5uy9lyIaH+bAe67REpokViq9AN6TS2tcSQx
			LwVf3pT6maEp1dIBXeg27QDq7mQrQbXFz7p8elxVFYc8qdjbm4VHzMAp8/MdkPKq
			ESugMkholL8X6yGELvSKwH3oh3UZbLy8qKKVrzqvKHD9rrttdNIkBK97UCE=
			-----END PGP MESSAGE-----
		'';
		authelia-storage.services = [ "authelia-main" ];
		authelia-storage.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0CAeDU1erv2TtfiYX27rbg8kNoB
			8xmSg3q5Rp3owa6cdjAg7qNjVCkGgzir6kL9zhSBy5DUt9stAw+tIdy+YlMnbuPj
			0H7U/BReHiv6ttMLyjDBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQHcSIwHR
			eWQBvKEiAqe2+NjSpTEAsJa07EnKJdrWKlQVMPUXM24QhOZrYr5ZucsY+Fr1uDBE
			IcwF+VNUH0DJhKrU7FYPoCsAI+OjllBG9zOWu9KWAgkCBqhPP4qbU6WMM4/qOFk/
			RM1fGsY4W5mKiACp2L6Xt9f3Xqo49iRfgIdWF7q9MWH1FeaUwQyFZd7AmIBxePi3
			ZdOThyyFJLX6oZJ0yH2EsE4iThbipHD0JCLjXMX6gI65jQZLAWwbqFEsKnXbiDn5
			ZBFuaIOEdUYq/gk6cz35ls2tWIL2PBzG0QYPF7sEkm0rtyA1
			-----END PGP MESSAGE-----
		'';
	};

	services.lldap = {
		enable = true;
		settings = {
			ldap_host = "127.0.0.1";
			http_host = "127.0.0.1";
			http_url = "https://${ldap}";
			ldap_base_dn = baseDN;
			# root: the declarative break-glass account, whose password
			# lldap-accounts generates; services bind as their own accounts.
			# people administer lldap as members of lldap_admin instead
			ldap_user_dn = "root";
			ldap_user_email = "root@${domain}";
			key_file = ""; # the key comes from LLDAP_KEY_SEED in lldap-env
			# root's password is declarative; changing it in the ui won't stick
			force_ldap_user_pass_reset = "always";
		};
		# without a jwt secret, nixpkgs' module makes one in /var/lib/lldap
		environmentFile = secret "lldap-env";
	};

	# authelia reads the directory and resets passwords of all but
	# lldap_admin, which is what its password reset needs and no more
	lldap.serviceAccounts.authelia.groups = [ "lldap_password_manager" ];

	crypt.generated = {
		authelia-jwt = {};
		authelia-session = {};
		# authelia as an openid connect provider, for services that log in
		# through it (grafana): the hmac secret signs its tokens' state, the
		# rsa key the tokens
		authelia-oidc-hmac.script = "openssl rand -hex 64 | tr -d '\\n' >$out";
		authelia-oidc-jwk.script = "openssl genrsa -out $out 4096";
	};

	services.authelia.instances.main = {
		enable = true;
		secrets = {
			jwtSecretFile = generated "authelia-jwt";
			sessionSecretFile = generated "authelia-session";
			# losing this one loses every second factor, so it stays in crypt
			storageEncryptionKeyFile = secret "authelia-storage";
			oidcHmacSecretFile = generated "authelia-oidc-hmac";
			oidcIssuerPrivateKeyFile = generated "authelia-oidc-jwk";
		};
		environmentVariables = {
			AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = "%d/ldap-password";
			AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE = "%d/smtp-password";
		};
		settings = {
			theme = "auto";
			server.address = "tcp://127.0.0.1:9091/";
			log = { level = "info"; format = "text"; };

			authentication_backend.ldap = {
				implementation = "lldap";
				address = "ldap://127.0.0.1:3890";
				base_dn = baseDN;
				user = config.lldap.serviceAccounts.authelia.dn;
			};

			# nothing is reachable unless a rule says so
			access_control = {
				default_policy = "deny";
				rules = [{
					domain = ldap;
					subject = [ "group:lldap_admin" ];
					policy = "two_factor";
				}];
			};

			session.cookies = [{
				inherit domain;
				authelia_url = "https://${auth}";
			}];
			storage.local.path = "/var/lib/authelia-main/db.sqlite3";
			# password resets and one-time codes, from fog (lemma/mail.nix)
			# through stalwart's submission, over loopback but checked
			# against mx's certificate
			notifier = {
				smtp = {
					address = "submissions://127.0.0.1:465";
					tls.server_name = "mx.${domain}";
					username = "fog";
					sender = "${domain} <fog@${domain}>";
					subject = "[${domain}] {title}";
				};
				# authelia shouldn't refuse to start, and lock everyone out,
				# because stalwart is down or fog isn't made yet
				disable_startup_check = true;
			};
			totp.issuer = domain;
		};
	};
	systemd.services.authelia-main = {
		wants = [ "lldap-accounts.service" ];
		after = [ "lldap-accounts.service" ];
		serviceConfig.LoadCredential = [
			"ldap-password:${config.lldap.serviceAccounts.authelia.passwordFile}"
			"smtp-password:${config.lldap.serviceAccounts.fog.passwordFile}"
		];
	};

	services.caddy.virtualHosts = {
		${auth}.extraConfig = ''
			reverse_proxy 127.0.0.1:9091
		'';
		# lldap's own ui, for lldap_admin with a second factor
		${ldap}.extraConfig = ''
			forward_auth 127.0.0.1:9091 {
				uri /api/authz/forward-auth
				copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
			}
			reverse_proxy 127.0.0.1:17170
		'';
	};
}
