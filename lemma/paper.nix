{ config, lib, pkgs, ... }: let
	domain = "amartia.online";
	paper = "paper.${domain}";
	auth = "auth.${domain}";
	port = 28981;
	# the documents themselves, on witness0 (lemma/box.nix): encrypted there,
	# and not on lemma0's own disk, which they would fill without bound
	media = "/srv/paper";

	# paperless's client secret, made on lemma0 with its pbkdf2 digest
	# beside it: paperless reads the secret, authelia only the digest
	oidc = config.crypt.generated.paperless-oidc.path;
	env = "/run/paperless-oidc/env";

	# logins through authelia, as allauth's openid connect provider. the
	# secret is added at start (paperless-oidc), since it's in this json
	providers = secret: {
		openid_connect = {
			SCOPE = [ "openid" "profile" "email" "groups" ];
			OAUTH_PKCE_ENABLED = true;
			APPS = [{
				provider_id = "authelia";
				name = domain;
				client_id = "paperless";
				inherit secret;
				settings = {
					server_url = "https://${auth}";
					token_auth_method = "client_secret_basic";
				};
			}];
		};
	};

	units = [ "paperless-web" "paperless-scheduler" "paperless-consumer" "paperless-task-queue" ];

	# what an account may do is its groups': `paper` may do everything with
	# documents, mail and their kinds, and see who there is to share with;
	# not paperless's own configuration, which is the superusers'
	groups = pkgs.writeText "paperless-groups.py" (lib.concatLines [
		"from django.contrib.auth.models import Group, Permission"
		"from django.db.models import Q"
		"group, _ = Group.objects.get_or_create(name='paper')"
		"group.permissions.set(Permission.objects.filter("
		"    Q(content_type__app_label__in=['documents', 'paperless_mail'])"
		"    | Q(content_type__app_label='auth', codename__in=['view_user', 'view_group'])))"
	]);
in {
	services.paperless = {
		enable = true;
		inherit port;
		mediaDir = media;
		# fog: the local admin, for when authelia is away. its password is
		# generated, and only read here to break glass
		passwordFile = config.crypt.generated.paperless-admin.path;
		environmentFile = env;
		settings = {
			PAPERLESS_URL = "https://${paper}";
			PAPERLESS_ADMIN_USER = "fog";
			# behind caddy, which says it was https
			PAPERLESS_PROXY_SSL_HEADER = [ "HTTP_X_FORWARDED_PROTO" "https" ];
			PAPERLESS_ALLAUTH_TRUSTED_PROXY_COUNT = 1;
			# the text of scans, in german and english
			PAPERLESS_OCR_LANGUAGE = "deu+eng";

			PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
			# a first login through authelia makes the account; nobody signs
			# up otherwise, and the login page goes straight to authelia
			PAPERLESS_SOCIAL_AUTO_SIGNUP = true;
			PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = true;
			PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = false;
			PAPERLESS_REDIRECT_LOGIN_TO_SSO = true;
			# each login sets the account's groups to those of lldap's that
			# paperless has (paper, from paperless-groups), and lldap_admin
			# makes a superuser
			PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS = true;
			PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP = "lldap_admin";
		};
	};

	crypt.generated = {
		paperless-admin = {};
		paperless-oidc.script = ''
			${pkgs.authelia}/bin/authelia crypto hash generate pbkdf2 \
				--variant sha512 --random --random.length 64 \
				--random.charset alphanumeric >$out.both
			sed -n 's/^Random Password: //p' $out.both | tr -d '\n' >$out
			sed -n 's/^Digest: //p' $out.both | tr -d '\n' >$out.digest
			rm $out.both
		'';
	};

	systemd.services = lib.genAttrs units (_: {
		requires = [ "paperless-oidc.service" ];
		after = [ "paperless-oidc.service" ];
		unitConfig.RequiresMountsFor = [ media ];
	}) // {
		# the providers' json with the secret in it, as an environment file
		# every paperless unit reads. alphanumeric, so single quotes hold it
		paperless-oidc = {
			description = "paperless's authelia login, with its secret";
			before = map (u: "${u}.service") units;
			serviceConfig = {
				Type = "oneshot";
				RemainAfterExit = true;
				RuntimeDirectory = "paperless-oidc";
				RuntimeDirectoryMode = "0700";
				LoadCredential = [ "oidc:${oidc}" ];
			};
			script = ''
				secret=$(cat "$CREDENTIALS_DIRECTORY/oidc")
				umask 077
				printf "PAPERLESS_SOCIALACCOUNT_PROVIDERS='%s'\n" \
					${lib.escapeShellArg (builtins.toJSON (providers "@secret@"))} |
					sed "s/@secret@/$secret/" >${env}
			'';
		};

		# the group `paper`, declared at every start, after the scheduler
		# migrated the database
		paperless-groups = {
			description = "paperless's group for lldap's paper";
			wantedBy = [ "multi-user.target" ];
			requires = [ "paperless-scheduler.service" ];
			after = [ "paperless-scheduler.service" ];
			partOf = [ "paperless-scheduler.service" ];
			serviceConfig = {
				Type = "oneshot";
				RemainAfterExit = true;
			};
			script = ''
				${lib.getExe' config.services.paperless.manage "paperless-manage"} shell -c "$(cat ${groups})"
			'';
		};

		authelia-main.serviceConfig.LoadCredential = [
			"paperless-oidc-digest:${oidc}.digest"
		];
	};

	services.authelia.instances.main.settings.identity_providers.oidc = {
		authorization_policies.paper = {
			default_policy = "deny";
			rules = [{ policy = "two_factor"; subject = "group:paper"; }];
		};
		clients = [{
			client_id = "paperless";
			client_name = "paper";
			client_secret = ''{{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/paperless-oidc-digest" | secret }}'';
			authorization_policy = "paper";
			require_pkce = true;
			pkce_challenge_method = "S256";
			redirect_uris = [ "https://${paper}/accounts/oidc/authelia/login/callback/" ];
			scopes = [ "openid" "profile" "email" "groups" ];
			grant_types = [ "authorization_code" ];
			response_types = [ "code" ];
			token_endpoint_auth_method = "client_secret_basic";
		}];
	};

	# who may: members of `paper`, added in lldap's ui or by invitation
	lldap.groups = [ "paper" ];
	invite.groups.paper = {
		label = "Paper";
		info = "documents, scanned and searchable, at https://${paper}, after a second factor you set up on first login";
	};

	services.caddy.virtualHosts.${paper}.extraConfig = ''
		reverse_proxy 127.0.0.1:${toString port}
	'';
}
