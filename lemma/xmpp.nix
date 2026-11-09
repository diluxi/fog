{ config, lib, pkgs, ... }: let
	domain = "amartia.online";
	baseDN = config.services.lldap.settings.ldap_base_dn;
	ldap = config.services.lldap.settings;
	account = config.lldap.serviceAccounts.ejabberd;

	# the components' addresses, ejabberd's defaults. each gets a certificate
	# for federation; upload is also where clients put and get files
	components = map (c: "${c}.${domain}") [ "conference" "pubsub" "upload" ];
	upload = "upload.${domain}";
	http = "127.0.0.1:5280";

	# caddy obtains every certificate; ejabberd reads them through
	# LoadCredential. amartia.online's own is ecdo's (ecdo.certified)
	certDir = "${config.services.caddy.dataDir}/.local/share/caddy/"
		+ "certificates/acme-v02.api.letsencrypt.org-directory";
	names = [ domain ] ++ components;
	creds = "/run/credentials/ejabberd.service";

	# lldap accounts that are services, not people: no login
	notService = lib.concatMapStrings (uid: "(!(uid=${uid}))")
		([ "root" ] ++ lib.attrNames config.lldap.serviceAccounts);

	settings = {
		hosts = [ domain ];
		loglevel = "info";
		certfiles = [ "${creds}/*.crt" "${creds}/*.key" ];

		listen = [
			{
				port = 5222;
				ip = "::";
				module = "ejabberd_c2s";
				max_stanza_size = 262144;
				shaper = "c2s_shaper";
				access = "c2s";
				starttls_required = true;
			}
			# direct tls (xep-0368)
			{
				port = 5223;
				ip = "::";
				module = "ejabberd_c2s";
				max_stanza_size = 262144;
				shaper = "c2s_shaper";
				access = "c2s";
				tls = true;
			}
			{
				port = 5269;
				ip = "::";
				module = "ejabberd_s2s_in";
				max_stanza_size = 524288;
				shaper = "s2s_shaper";
			}
			# file uploads, behind caddy
			{
				port = 5280;
				ip = "127.0.0.1";
				module = "ejabberd_http";
				request_handlers."/upload" = "mod_http_upload";
			}
		];
		s2s_use_starttls = "required";

		# accounts are lldap's people. ejabberd searches as `ejabberd` (in
		# lldap_strict_readonly) and checks passwords by binding as the user.
		# ldap_password comes from the file written at start
		auth_method = "ldap";
		ldap_servers = [ ldap.ldap_host ];
		ldap_port = ldap.ldap_port;
		ldap_rootdn = account.dn;
		ldap_base = "ou=people,${baseDN}";
		ldap_uids.uid = "%u";
		ldap_filter = "(&(objectClass=person)${notService})";
		include_config_file = "/run/ejabberd/ldap.yml";

		# everything else in sqlite: archives in mnesia break at 2GB
		default_db = "sql";
		sql_type = "sqlite";
		sql_database = "${config.services.ejabberd.spoolDir}/ejabberd.db";

		acl = {
			local.user_regexp = "";
			admin.user = [ "lux@${domain}" ];
		};
		access_rules = {
			local.allow = "local";
			c2s = { deny = "blocked"; allow = "all"; };
			announce.allow = "admin";
			configure.allow = "admin";
			muc_create.allow = "local";
			pubsub_createnode.allow = "local";
		};
		api_permissions."console commands" = {
			from = "ejabberd_ctl";
			who = "all";
			what = "*";
		};

		shaper = {
			normal = { rate = 3000; burst_size = 20000; };
			fast = 100000;
		};
		shaper_rules = {
			max_user_sessions = 10;
			# upstream gives admins 5000 and others 100, but its numbers are
			# yaml keys, which nix can only write as strings
			max_user_offline_messages = 1000;
			c2s_shaper = { none = "admin"; normal = "all"; };
			s2s_shaper = "fast";
		};

		# upstream's example, without registration, web admin, http api,
		# bosh, mqtt, proxy65 and stun
		modules = {
			mod_adhoc = {};
			mod_admin_extra = {};
			mod_announce.access = "announce";
			mod_avatar = {};
			mod_blocking = {};
			mod_caps = {};
			mod_carboncopy = {};
			mod_client_state = {};
			mod_configure = {};
			mod_disco = {};
			mod_fail2ban = {};
			mod_http_upload = {
				put_url = "https://${upload}/upload";
				hosts = [ upload ];
			};
			# shared files are kept for a month
			mod_http_upload_quota.max_days = 30;
			mod_last = {};
			mod_mam = {
				assume_mam_usage = true;
				default = "always";
			};
			mod_muc = {
				access = [ "allow" ];
				access_admin = [ { allow = "admin"; } ];
				access_create = "muc_create";
				access_persistent = "muc_create";
				access_mam = [ "allow" ];
				default_room_options.mam = true;
			};
			mod_offline.access_max_user_messages = "max_user_offline_messages";
			mod_ping = {};
			mod_privacy = {};
			mod_private = {};
			# pep, which omemo's keys and bookmarks live in
			mod_pubsub = {
				access_createnode = "pubsub_createnode";
				plugins = [ "flat" "pep" ];
				force_node_config."storage:bookmarks".access_model = "whitelist";
			};
			mod_push = {};
			mod_push_keepalive = {};
			mod_roster.versioning = true;
			mod_s2s_bidi = {};
			mod_s2s_dialback = {};
			mod_stream_mgmt.resend_on_timeout = "if_offline";
			mod_vcard = {};
			mod_vcard_xupdate = {};
			mod_version.show_os = false;
		};
	};
in {
	services.ejabberd = {
		enable = true;
		package = pkgs.ejabberd.override { withSqlite = true; };
		configFile = (pkgs.formats.yaml {}).generate "ejabberd.yml" settings;
	};

	lldap.serviceAccounts.ejabberd.groups = [ "lldap_strict_readonly" ];

	ecdo.certified = [ domain ];

	systemd.services.ejabberd = {
		wants = [ "lldap-accounts.service" ];
		after = [ "lldap-accounts.service" "caddy.service" ];
		serviceConfig = {
			RuntimeDirectory = "ejabberd";
			RuntimeDirectoryMode = "0700";
			LoadCredential = [ "ldap:${account.passwordFile}" ]
				++ lib.concatMap (name: [
					"${name}.crt:${certDir}/${name}/${name}.crt"
					"${name}.key:${certDir}/${name}/${name}.key"
				]) names;
		};
		# the password is hex, so it needs no escaping in yaml
		preStart = ''
			(umask 077; printf 'ldap_password: "%s"\n' "$(<"$CREDENTIALS_DIRECTORY/ldap")" \
				>/run/ejabberd/ldap.yml)
		'';
	};

	# a renewed certificate only reaches ejabberd through a restart, since
	# LoadCredential copies it at start
	systemd.paths.ejabberd-certificate = {
		wantedBy = [ "multi-user.target" ];
		pathConfig.PathChanged = map (name: "${certDir}/${name}/${name}.crt") names;
	};
	systemd.services.ejabberd-certificate = {
		serviceConfig.Type = "oneshot";
		script = "systemctl try-restart ejabberd.service";
	};

	networking.firewall.allowedTCPPorts = [ 5222 5223 5269 ];

	services.caddy.virtualHosts = lib.genAttrs components (name: {
		extraConfig = ''
			# pin the issuer, so the certificate stays where ejabberd looks for it
			tls {
				issuer acme {
					dir https://acme-v02.api.letsencrypt.org/directory
				}
			}
		'' + (if name == upload then ''
			reverse_proxy ${http}
		'' else ''
			respond 404
		'');
	});
}
