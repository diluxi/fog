{ config, lib, pkgs, ... }: let
	domain = "amartia.online";
	shelf = "shelf.${domain}";
	auth = "auth.${domain}";
	port = 5000;
	shelf-tree = "/srv/shelf";

	# kavita's client secret, made on lemma0 with its pbkdf2 digest beside it:
	# kavita reads the secret, authelia only the digest
	oidc = config.crypt.generated.kavita-oidc.path;

	# kavita's libraries, as its api takes them. provider is kavita+'s
	# metadata source, which each type must name though nothing here asks
	# it: matching and scrobbling are off. files are its groups: archives
	# 1, epub 2, pdf 3
	libraries = [
		{ name = "Manga"; type = 0; provider = 3; files = [ 1 3 ]; }
		{ name = "Comics"; type = 1; provider = 4; files = [ 1 3 ]; }
		{ name = "Books"; type = 2; provider = 2; files = [ 2 3 ]; }
	];
	library = l: {
		inherit (l) name type;
		folders = [ "${shelf-tree}/${l.name}" ];
		metadataProvider = l.provider;
		fileGroupTypes = l.files;
		# inotify doesn't reach through gocryptfs and smb
		folderWatching = false;
		includeInDashboard = true;
		includeInSearch = true;
		manageCollections = true;
		manageReadingLists = true;
		allowScrobbling = false;
		allowMetadataMatching = false;
		# comicinfo.xml and the like, from the files themselves
		enableMetadata = true;
		removePrefixForSortName = false;
		inheritWebLinksFromFirstChapter = false;
		defaultLanguage = "";
		excludePatterns = [];
	};

	# what a login through authelia makes, besides the issuer, client and
	# secret in appsettings.json: an account for every member of shelf, with
	# every library. the password login stays for fog
	oidcSettings = {
		providerName = domain;
		provisionAccounts = true;
		syncUserSettings = false;
		defaultRoles = [ "Login" ];
		autoLogin = false;
		disablePasswordAuthentication = false;
	};
in {
	# kavita reads manga, comics and books from the libraries odos makes in
	# /srv/shelf, links into /srv/seed/{manga,comics,books} (lemma/box.nix)
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
		# fog's password in kavita, which only kavita-setup types
		kavita-admin = {};
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
	# shelf to read its libraries and what their links lead to, and nothing
	# of kino's
	users.users.kavita.extraGroups = [ "shelf" ];
	systemd.services.kavita.unitConfig.RequiresMountsFor =
		[ shelf-tree ] ++ map (kind: "/srv/seed/${kind}") [ "manga" "comics" "books" ];

	# what kavita keeps in its database, declared through its api as its
	# admin fog: the libraries, and what a login through authelia makes.
	# fog is the first account, which kavita lets anyone make while it has
	# no admin; its address is the one lldap's fog has, so no member of
	# shelf can have it, as kavita joins a login to an account by address
	systemd.services.kavita-setup = {
		description = "kavita's admin, libraries and logins";
		wantedBy = [ "multi-user.target" ];
		requires = [ "kavita.service" ];
		after = [ "kavita.service" ];
		partOf = [ "kavita.service" ];
		path = with pkgs; [ curl jq ];
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
			DynamicUser = true;
			RuntimeDirectory = "kavita-setup";
			RuntimeDirectoryMode = "0700";
			LoadCredential = [ "admin:${config.crypt.generated.kavita-admin.path}" ];
			Restart = "on-failure";
			RestartSec = "30s";
		};
		script = ''
			api=http://127.0.0.1:${toString port}/api
			for i in $(seq 120); do curl -sf $api/health >/dev/null && break; sleep 1; done

			# the password through jq and stdin, never on a command line
			account() {
				jq -nc --rawfile p "$CREDENTIALS_DIRECTORY/admin" \
					'{username: "fog", email: "fog@${domain}", password: $p}' |
					curl -s -H 'content-type: application/json' --data @- "$api/account/$1"
			}
			# kavita refuses this once it has an admin
			account register >/dev/null
			if ! token=$(account login | jq -er .token 2>/dev/null); then
				echo "kavita won't let fog in: it has an admin of its own. make fog an admin" >&2
				echo "with the password in ${config.crypt.generated.kavita-admin.path}, or start kavita afresh" >&2
				exit 1
			fi
			rc=$RUNTIME_DIRECTORY/curlrc
			printf 'header = "Authorization: Bearer %s"\nheader = "content-type: application/json"\n' \
				"$token" >"$rc"
			get() { curl -sSf -K "$rc" "$api/$1"; }
			post() { curl -sSf -K "$rc" --data-binary @- "$api/$1" >/dev/null; }

			# each library made, or made what it's declared to be again
			have=$(get library/libraries)
			jq -c '.[]' <<<${lib.escapeShellArg (builtins.toJSON (map library libraries))} | while read -r want; do
				name=$(jq -r .name <<<"$want")
				if id=$(jq -e --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$have"); then
					jq -c --argjson id "$id" '.id = $id' <<<"$want" | post library/update
				else
					echo "making the library $name"
					jq -c '.id = 0' <<<"$want" | post library/create
				fi
			done

			# logins through authelia, with every library. kavita hands back its
			# secret masked, and keeps the one it has when it gets the mask
			ids=$(get library/libraries | jq -c 'map(.id)')
			get settings | jq -c --argjson ids "$ids" \
				--argjson oidc ${lib.escapeShellArg (builtins.toJSON oidcSettings)} \
				'.oidcConfig += $oidc + {defaultLibraries: $ids}' | post settings

			# and a scan: kavita scans a library when it's made, and after an
			# update only when its number of folders or its type changed, and
			# odos doesn't tell it of new links
			curl -sSf -K "$rc" -X POST "$api/library/scan-all" >/dev/null
		'';
	};

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
