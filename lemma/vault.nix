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
	crypt.secrets.vaultwarden-env.text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0CeX+Js8itVfaDdRLziOw4IfPD/
		BDMfahU226CTjP/rbzBKjl/TwhJQ/DbFb4TQaPiw3TvXeplmlCk+SkqkvUycCy9N
		mxdbntWIEJ7foSkDvD/BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQKZlm0bt
		iMGZlGjskKTFdZ7rtv/Qge5GXLNPsfGTbQ49MCblVMp26naJb1pfvSUR4c8hRKBk
		QqLf+Oc7dcHnCH87QZomGNZxhbv2UUJoFz2vydLAFgIJAgYiWqjheFka6PIVPqr9
		UVIrrG2Xp4/rLKO49D0Tf+mzB0Y7tlKbeYzWJ+0fEHbrsJK+hP+rsTNJEaDJ+biv
		VCSzsxlfUVVIc0KtvJ5ZieBoqtIiWXX3FCLeFWp8Z1hpucNWT09ktff4H8GEVOcm
		Q43IrG0fY+QpwoUfGemGweoAaCGxKyx5f1PAD7+o6hEra1mIbtzzv5FXzlKenuK9
		FLjrSXjBHBSInMQ1L4tFMsKKg4nwYjnFidm5hiRkzyPTRGatjXpA7muvC4zYg03V
		sWC8VyI=
		-----END PGP MESSAGE-----
	'';

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
