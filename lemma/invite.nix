{ config, lib, pkgs, ... }: let
	cfg = config.invite;
	host = "invite.amartia.online";
	port = 8097;
	settings = config.services.lldap.settings;
	account = config.lldap.serviceAccounts.invite;

	invite = pkgs.buildGoModule {
		pname = "invite";
		version = "0";
		src = ./invite;
		vendorHash = null;
	};

	# credentials are per unit, so each unit gets its own copy
	configFile = unit: pkgs.writeText "${unit}.json" (builtins.toJSON {
		listen = "127.0.0.1:${toString port}";
		url = "https://${host}";
		lldapHttp = "http://${settings.http_host}:${toString settings.http_port}";
		lldapLdap = "ldap://${settings.ldap_host}:${toString settings.ldap_port}";
		baseDn = settings.ldap_base_dn;
		user = "invite";
		passwordFile = "/run/credentials/${unit}.service/ldap";
		keyFile = "/run/credentials/${unit}.service/key";
		stateDir = "/var/lib/invite";
		ldappasswd = "${pkgs.openldap}/bin/ldappasswd";
		adminGroup = "lldap_admin";
		mailGroup = "mail";
		mailDomain = "amartia.online";
		localDomains = [ "amartia.online" "cpli.dev" ];
		reserved = lib.unique cfg.reserved;
		services = [ "root" ] ++ lib.attrNames config.lldap.serviceAccounts;
		groups = lib.mapAttrsToList (name: g: { inherit name; inherit (g) label info; })
			cfg.groups;
		existing = cfg.existing;
	});

	unit = name: command: {
		path = [ pkgs.openldap ];
		serviceConfig = {
			ExecStart = "${invite}/bin/invite -config ${configFile name} ${command}";
			DynamicUser = true;
			StateDirectory = "invite";
			StateDirectoryMode = "0700";
			LoadCredential = [
				"ldap:${account.passwordFile}"
				"key:${config.crypt.generated.invite-key.path}"
			];
			PrivateTmp = true;
			ProtectSystem = "strict";
			ProtectHome = true;
			NoNewPrivileges = true;
			RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
			CapabilityBoundingSet = "";
			SystemCallArchitectures = "native";
		};
	};
in {
	options.invite = {
		groups = lib.mkOption {
			description = ''
				Groups an invitation may give, with how they're shown: in the
				admin's form, and after signing up, what the account can now do.
			'';
			default = {};
			type = lib.types.attrsOf (lib.types.submodule {
				options = {
					label = lib.mkOption { type = lib.types.str; };
					info = lib.mkOption { type = lib.types.str; };
				};
			});
		};
		existing = lib.mkOption {
			description = ''
				Groups every person already in lldap joins once, when access
				that used to be everyone's became a group.
			'';
			type = lib.types.listOf lib.types.str;
			default = [];
		};
		reserved = lib.mkOption {
			description = "Usernames nobody may pick: addresses and roles.";
			type = lib.types.listOf lib.types.str;
		};
	};

	config = {
		invite.reserved = [
			"root" "admin" "administrator" "postmaster" "abuse" "hostmaster"
			"webmaster" "noreply" "no-reply" "mailer-daemon" "www" "mail" "mx"
			"xmpp" "invite" "auth" "ldap" "support" "security"
		] ++ lib.attrNames config.lldap.serviceAccounts;

		lldap.groups = lib.attrNames cfg.groups;
		# creating people takes an admin; the hmac checks happen before any of
		# its requests, and only over loopback
		lldap.serviceAccounts.invite.groups = [ "lldap_admin" ];
		crypt.generated.invite-key = {};

		systemd.services.invite = lib.recursiveUpdate (unit "invite" "serve") {
			description = "invitation links that make lldap accounts";
			wantedBy = [ "multi-user.target" ];
			wants = [ "lldap-accounts.service" ];
			after = [ "lldap-accounts.service" ];
			serviceConfig.Restart = "on-failure";
		};

		# mail and xmpp used to be everyone's. before either reads the new
		# groups, everyone already here joins them, once
		systemd.services.invite-migrate = lib.recursiveUpdate (unit "invite-migrate" "migrate") {
			description = "move everyone into the groups that were everyone's";
			wantedBy = [ "multi-user.target" ];
			requires = [ "lldap-accounts.service" ];
			after = [ "lldap-accounts.service" ];
			before = [ "stalwart.service" "ejabberd.service" ];
			serviceConfig = {
				Type = "oneshot";
				RemainAfterExit = true;
			};
		};
		# making links is for lldap_admin with a second factor; following one
		# needs nothing but the link
		services.authelia.instances.main.settings.access_control.rules = [{
			domain = host;
			resources = [ "^/new([/?].*)?$" ];
			subject = [ "group:lldap_admin" ];
			policy = "two_factor";
		}];
		# in this order: whatever Remote-* a client sends is dropped, then
		# authelia's are set for /new, which is the only place they're read
		services.caddy.virtualHosts.${host}.extraConfig = ''
			route {
				request_header -Remote-User
				request_header -Remote-Groups
				request_header -Remote-Email
				request_header -Remote-Name
				@new path /new /new/*
				forward_auth @new 127.0.0.1:9091 {
					uri /api/authz/forward-auth
					copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
				}
				reverse_proxy 127.0.0.1:${toString port}
			}
		'';
	};
}
