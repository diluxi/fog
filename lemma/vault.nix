{ config, ... }: let
	vault = "vault.amartia.online";
	port = 8222;

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';
in {
	# ADMIN_TOKEN as an argon2 hash, in systemd EnvironmentFile syntax.
	# vaultwarden prints the line itself, single quotes included
	crypt.secrets.vaultwarden-env.text = todo "vaultwarden-env"
		"$(nix-build --no-out-link -A pkgs.vaultwarden)/bin/vaultwarden hash";

	services.vaultwarden = {
		enable = true;
		dbBackend = "sqlite";
		# daily copies of the database and attachments; on lemma0 only
		backupDir = "/var/backup/vaultwarden";
		environmentFile = config.crypt.secrets.vaultwarden-env.path;
		config = {
			DOMAIN = "https://${vault}";
			ROCKET_ADDRESS = "127.0.0.1";
			ROCKET_PORT = port;
			IP_HEADER = "X-Forwarded-For";

			# no open sign-ups: accounts come from invitations in the admin panel
			SIGNUPS_ALLOWED = false;
			INVITATIONS_ALLOWED = true;
			SHOW_PASSWORD_HINT = false;
			PASSWORD_HINTS_ALLOWED = false;
		};
	};

	# the admin panel sits behind authelia as well as its own token
	services.authelia.instances.main.settings.access_control.rules = [{
		domain = vault;
		resources = [ "^/admin([/?].*)?$" ];
		subject = [ "group:lldap_admin" ];
		policy = "two_factor";
	}];

	services.caddy.virtualHosts.${vault}.extraConfig = ''
		@admin path /admin /admin/*
		forward_auth @admin 127.0.0.1:9091 {
			uri /api/authz/forward-auth
			copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
		}
		reverse_proxy 127.0.0.1:${toString port}
	'';
}
