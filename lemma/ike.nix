{ config, lib, pkgs, ... }: let
	cfg = config.services.ike;
	host = "ike.amartia.online";
	auth = "auth.amartia.online";

	# ike's client secret, made on lemma0 with its pbkdf2 digest beside it:
	# ike reads the secret, authelia only the digest
	oidc = config.crypt.generated.ike-oidc.path;
in {
	crypt.generated.ike-oidc.script = ''
		${pkgs.authelia}/bin/authelia crypto hash generate pbkdf2 \
			--variant sha512 --random --random.length 64 \
			--random.charset alphanumeric >$out.both
		sed -n 's/^Random Password: //p' $out.both | tr -d '\n' >$out
		sed -n 's/^Digest: //p' $out.both | tr -d '\n' >$out.digest
		rm $out.both
	'';

	services.ike = {
		enable = true;
		boards = {
			b = "random";
			meta = "about ike";
		};
		caddy = {
			enable = true;
			hostName = host;
		};
		# its own origin, so uploads never share ike's. this one is under
		# amartia.online, where authelia's cookie reaches it too; accepted
		# while ike is not public
		media.origin = "https://cdn.amartia.online";
		oidc = {
			issuer = "https://${auth}";
			clientId = "ike";
			redirectUri = "https://${host}/login/callback";
			clientSecretFile = oidc;
		};
		# stubs. caddy lets an upload through up to maxBytes x files + 1 MiB,
		# and the defaults' 20 files would be about 400 MiB a request
		strip = {
			maxBytes = 20971520;
			files = 5;
		};
	};

	services.authelia.instances.main.settings.identity_providers.oidc = {
		# ike reads the nick and the roles from the id token, never from
		# userinfo, and authelia leaves both out of it unless asked
		claims_policies.ike.id_token = [ "preferred_username" "groups" ];
		clients = [{
			client_id = "ike";
			client_name = "ike";
			# the template filter (on for the oidc key) reads the digest
			client_secret = ''{{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/ike-oidc-digest" | secret }}'';
			claims_policy = "ike";
			require_pkce = true;
			pkce_challenge_method = "S256";
			redirect_uris = [ cfg.oidc.redirectUri ];
			# ike asks for groups at every login; a scope the client isn't
			# granted fails the whole request
			scopes = [ "openid" "profile" "groups" ];
			grant_types = [ "authorization_code" ];
			response_types = [ "code" ];
			id_token_signed_response_alg = "RS256";
			token_endpoint_auth_method = "client_secret_basic";
		}];
	};
	systemd.services.authelia-main.serviceConfig.LoadCredential = [
		"ike-oidc-digest:${oidc}.digest"
	];

	# the roles' groups, a janitor's one per board. who is in them is the
	# ui's: lux goes in ike-admin by hand
	lldap.groups = [ cfg.roles.admin cfg.roles.moderator ]
		++ map (board: cfg.roles.janitor + board) (lib.attrNames cfg.boards);
}
