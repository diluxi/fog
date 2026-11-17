{ config, pkgs, ... }: let
	domain = "amartia.online";
	shelf = "shelf.${domain}";
	auth = "auth.${domain}";
	port = 5000;
	kino = "/srv/kino";

	# kavita's client secret, made on lemma0 with its pbkdf2 digest beside it:
	# kavita reads the secret, authelia only the digest
	oidc = config.crypt.generated.kavita-oidc.path;
in {
	# kavita reads manga, comics and books from the libraries odos makes in
	# /srv/kino, links into /srv/seed/{manga,comics,books} (lemma/box.nix)
	services.kavita = {
		enable = true;
		settings = {
			IpAddresses = "127.0.0.1";
			Port = port;
			# logins through authelia. what kavita does with them (making
			# accounts, their libraries) is in its own database, set once in
			# its ui: phi.md says how
			OpenIdConnectSettings = {
				Authority = "https://${auth}";
				ClientId = "kavita";
				Secret = "@oidc@";
				CustomScopes = [ "groups" ];
			};
		};
		credentials = {
			token_key = config.crypt.generated.kavita-token.path;
			inherit oidc;
		};
	};
	crypt.generated = {
		# signs kavita's own tokens: 512 bits at least
		kavita-token.script = "head -c 64 /dev/urandom | base64 --wrap=0 >$out";
		kavita-oidc.script = ''
			${pkgs.authelia}/bin/authelia crypto hash generate pbkdf2 \
				--variant sha512 --random --random.length 64 \
				--random.charset alphanumeric >$out.both
			sed -n 's/^Random Password: //p' $out.both | tr -d '\n' >$out
			sed -n 's/^Digest: //p' $out.both | tr -d '\n' >$out.digest
			rm $out.both
		'';
	};
	# kino to reach /srv/kino, shelf to read what its links lead to
	users.users.kavita.extraGroups = [ "kino" "shelf" ];
	systemd.services.kavita.unitConfig.RequiresMountsFor =
		[ kino ] ++ map (kind: "/srv/seed/${kind}") [ "manga" "comics" "books" ];

	services.authelia.instances.main.settings.identity_providers.oidc = {
		authorization_policies.shelf = {
			default_policy = "deny";
			rules = [{ policy = "two_factor"; subject = "group:shelf"; }];
		};
		clients = [{
			client_id = "kavita";
			client_name = "shelf";
			# the template filter (on for the oidc key) reads the digest
			client_secret = ''{{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/kavita-oidc-digest" | secret }}'';
			authorization_policy = "shelf";
			require_pkce = true;
			pkce_challenge_method = "S256";
			redirect_uris = [ "https://${shelf}/signin-oidc" ];
			# kavita asks for offline_access, and email to make an account;
			# it drops roles, which authelia doesn't offer
			scopes = [ "openid" "profile" "email" "groups" "offline_access" ];
			grant_types = [ "authorization_code" "refresh_token" ];
			response_types = [ "code" ];
			# asp.net's handler sends the secret in the body
			token_endpoint_auth_method = "client_secret_post";
		}];
	};
	systemd.services.authelia-main.serviceConfig.LoadCredential = [
		"kavita-oidc-digest:${oidc}.digest"
	];

	# who may: members of `shelf`, added in lldap's ui or by invitation
	lldap.groups = [ "shelf" ];
	invite.groups.shelf = {
		label = "Shelf";
		info = "manga, comics and books at https://${shelf}, after a second factor you set up on first login";
	};

	services.caddy.virtualHosts.${shelf}.extraConfig = ''
		reverse_proxy 127.0.0.1:${toString port}
	'';
}
