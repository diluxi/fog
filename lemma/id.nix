{ config, ... }: let
	domain = "amartia.online";
	baseDN = "dc=amartia,dc=online";
	auth = "auth.${domain}";
	ldap = "ldap.${domain}";

	# secrets reach both services through LoadCredential, so they stay
	# root-owned in /run/crypt; lldap's DynamicUser doesn't exist at activation
	secret = name: config.crypt.secrets.${name}.path;

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';
in {
	crypt.secrets = {
		# lldap's admin, which authelia also binds as for now
		lldap-admin.text = todo "lldap-admin" "openssl rand -base64 33";
		lldap-jwt.text = todo "lldap-jwt" "openssl rand -base64 48";
		# key_seed derives lldap's password-hashing key. losing it voids every
		# stored password, so it lives here rather than only in /var/lib
		lldap-env.text = todo "lldap-env"
			"printf 'LLDAP_KEY_SEED=%s\\n' \"$(openssl rand -hex 32)\"";
		authelia-jwt.text = todo "authelia-jwt" "openssl rand -base64 48";
		authelia-session.text = todo "authelia-session" "openssl rand -base64 48";
		authelia-storage.text = todo "authelia-storage" "openssl rand -base64 48";
	};

	services.lldap = {
		enable = true;
		settings = {
			ldap_host = "127.0.0.1";
			http_host = "127.0.0.1";
			http_url = "https://${ldap}";
			ldap_base_dn = baseDN;
			ldap_user_email = "lux@${domain}";
			key_file = ""; # the key comes from LLDAP_KEY_SEED in lldap-env
			# the admin password is declarative; changing it in the ui won't stick
			force_ldap_user_pass_reset = "always";
		};
		environment = {
			LLDAP_JWT_SECRET_FILE = "%d/jwt";
			LLDAP_LDAP_USER_PASS_FILE = "%d/admin";
		};
		environmentFile = secret "lldap-env";
	};
	systemd.services.lldap.serviceConfig.LoadCredential = [
		"jwt:${secret "lldap-jwt"}"
		"admin:${secret "lldap-admin"}"
	];

	services.authelia.instances.main = {
		enable = true;
		secrets = {
			jwtSecretFile = secret "authelia-jwt";
			sessionSecretFile = secret "authelia-session";
			storageEncryptionKeyFile = secret "authelia-storage";
		};
		environmentVariables.AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE =
			"%d/ldap-password";
		settings = {
			theme = "auto";
			server.address = "tcp://127.0.0.1:9091/";
			log = { level = "info"; format = "text"; };

			authentication_backend.ldap = {
				implementation = "lldap";
				address = "ldap://127.0.0.1:3890";
				base_dn = baseDN;
				user = "uid=admin,ou=people,${baseDN}";
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
			# no mail until stalwart: read with run0 cat
			notifier.filesystem.filename = "/var/lib/authelia-main/notifications.txt";
			totp.issuer = domain;
		};
	};
	systemd.services.authelia-main = {
		wants = [ "lldap.service" ];
		after = [ "lldap.service" ];
		serviceConfig.LoadCredential = [ "ldap-password:${secret "lldap-admin"}" ];
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
