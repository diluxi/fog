{ config, lib, pkgs, ... }: let
	kino = "kino.amartia.online";
	dataDir = config.services.jellyfin.dataDir;
	baseDN = config.services.lldap.settings.ldap_base_dn;
	group = name: "cn=${name},ou=groups,${baseDN}";
	account = config.lldap.serviceAccounts.jellyfin;

	# jellyfin's ldap plugin, pinned here instead of installed in the ui.
	# 24.0.0.0 targets jellyfin's 12.0 abi
	ldapPlugin = {
		name = "LDAP Authentication";
		version = "24.0.0.0";
		src = pkgs.fetchzip {
			url = "https://repo.jellyfin.org/files/plugin/ldap-authentication/ldap-authentication_24.0.0.0.zip";
			sha256 = "0qwn8rhqn6zxbqaqc8pw13x6bz710bx5828yb36xrykgm0nshb6a";
			stripRoot = false;
		};
	};

	# the plugin's settings. @BINDPW@ and @LDAPUSERS@ are filled in at start:
	# the generated password, and the plugin's own links between ldap and
	# jellyfin users, carried over from the previous file
	ldapConfig = pkgs.writeText "LDAP-Auth.xml" ''
		<?xml version="1.0" encoding="utf-8"?>
		<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
		@LDAPUSERS@
		  <LdapServer>${config.services.lldap.settings.ldap_host}</LdapServer>
		  <LdapPort>${toString config.services.lldap.settings.ldap_port}</LdapPort>
		  <UseSsl>false</UseSsl>
		  <UseStartTls>false</UseStartTls>
		  <SkipSslVerify>false</SkipSslVerify>
		  <LdapBindUser>${account.dn}</LdapBindUser>
		  <LdapBindPassword>@BINDPW@</LdapBindPassword>
		  <LdapBaseDn>ou=people,${baseDN}</LdapBaseDn>
		  <LdapSearchFilter>(memberOf=${group "kino"})</LdapSearchFilter>
		  <LdapAdminBaseDn />
		  <LdapAdminFilter>(memberOf=${group "lldap_admin"})</LdapAdminFilter>
		  <EnableLdapAdminFilterMemberUid>false</EnableLdapAdminFilterMemberUid>
		  <LdapSearchAttributes>uid, mail</LdapSearchAttributes>
		  <LdapClientCertPath />
		  <LdapClientKeyPath />
		  <LdapRootCaPath />
		  <CreateUsersFromLdap>true</CreateUsersFromLdap>
		  <AllowPassChange>false</AllowPassChange>
		  <LdapUidAttribute>uid</LdapUidAttribute>
		  <LdapUsernameAttribute>uid</LdapUsernameAttribute>
		  <LdapPasswordAttribute>userPassword</LdapPasswordAttribute>
		  <EnableLdapProfileImageSync>false</EnableLdapProfileImageSync>
		  <RemoveImagesNotInLdap>false</RemoveImagesNotInLdap>
		  <LdapProfileImageAttribute>jpegphoto</LdapProfileImageAttribute>
		  <LdapProfileImageFormat>Default</LdapProfileImageFormat>
		  <EnableAllFolders>true</EnableAllFolders>
		  <EnabledFolders />
		  <PasswordResetUrl>https://auth.amartia.online/reset-password/step1</PasswordResetUrl>
		</PluginConfiguration>
	'';
	# jellyfin's libraries, which it keeps as files and reads at start: a
	# directory per library under root/default, its type as an empty
	# <type>.collection (none: mixed films and shows), and a .mblink per
	# folder holding the folder's path (their names don't matter). options.xml, its settings from the
	# ui, keeps a copy of the paths too. libraries named here are made to
	# match at every start; others, and every other setting, are left alone
	libraries = {
		TV = { type = null; paths = [ "/srv/kino" "/srv/seed/video" ]; };
	};
	libraryScript = name: l: let
		dir = "${dataDir}/root/default/${name}";
		xml = lib.replaceStrings [ "&" "<" ">" ] [ "&amp;" "&lt;" "&gt;" ];
	in ''
		dir=${lib.escapeShellArg dir}
		mkdir -p "$dir"
		find "$dir" -maxdepth 1 \( -name '*.collection' -o -name '*.mblink' \) -delete
		${lib.optionalString (l.type != null) ''
			: >"$dir"/${lib.escapeShellArg "${l.type}.collection"}
		''}
		${lib.concatStrings (lib.imap1 (i: p: ''
			printf %s ${lib.escapeShellArg p} >"$dir"/${lib.escapeShellArg "${toString i}-${baseNameOf p}.mblink"}
		'') l.paths)}
		if [ -f "$dir/options.xml" ]; then
			PATHS=${lib.escapeShellArg (lib.concatMapStrings (p: "${xml p}\n") l.paths)} awk '
				function infos(  n, a, i) {
					print "  <PathInfos>"
					n = split(ENVIRON["PATHS"], a, "\n")
					for (i = 1; i < n; i++)
						printf "    <MediaPathInfo>\n      <Path>%s</Path>\n    </MediaPathInfo>\n", a[i]
					print "  </PathInfos>"
				}
				/<PathInfos *\/>/ { infos(); next }
				/<PathInfos>/ { infos(); skip = 1; next }
				skip && /<\/PathInfos>/ { skip = 0; next }
				!skip
			' "$dir/options.xml" >"$dir/options.xml.new"
			mv "$dir/options.xml.new" "$dir/options.xml"
		fi
	'';
in {
	services.jellyfin = {
		enable = true;
		openFirewall = false; # only via caddy or the fog interface
	};

	# who may watch: members of `kino`, added in lldap's ui. lldap_admin
	# members become jellyfin admins
	lldap.groups = [ "kino" ];
	invite.groups.kino = {
		label = "Kino";
		info = "films and series at https://${kino}, in a browser or the Jellyfin apps";
	};
	lldap.serviceAccounts.jellyfin.groups = [ "lldap_strict_readonly" ];

	systemd.services.jellyfin = {
		# its libraries are in /srv/kino (lemma/box.nix), linking into
		# /srv/seed/video. it reads both and writes neither
		unitConfig.RequiresMountsFor = [ "/srv/kino" "/srv/seed/video" ];
		serviceConfig.ReadOnlyPaths = [ "/srv/kino" "/srv/seed" ];
		wants = [ "lldap-accounts.service" ];
		after = [ "lldap-accounts.service" ];
		serviceConfig.LoadCredential = [ "ldap:${account.passwordFile}" ];
		path = [ pkgs.gawk ];
		preStart = lib.concatStrings (lib.mapAttrsToList libraryScript libraries) + ''
			plugins=${lib.escapeShellArg "${dataDir}/plugins"}
			dir="$plugins/${ldapPlugin.name}_${ldapPlugin.version}"
			if [ ! -d "$dir" ]; then
				# jellyfin rewrites meta.json, so a copy rather than a link
				rm -rf "$plugins/${ldapPlugin.name}_"*
				mkdir -p "$plugins"
				cp -r ${ldapPlugin.src} "$dir"
				chmod -R u+w "$dir"
			fi

			conf="$plugins/configurations/LDAP-Auth.xml"
			mkdir -p "$plugins/configurations"
			users='<LdapUsers />'
			if [ -f "$conf" ]; then
				old=$(awk '/<LdapUsers *\/>/ { print; exit }
					/<LdapUsers>/ { f = 1 } f { print } /<\/LdapUsers>/ { exit }' "$conf")
				[ -n "$old" ] && users=$old
			fi
			# the password comes from a file and the links from the environment,
			# so neither ends up on a command line
			USERS=$users awk -v pwfile="$CREDENTIALS_DIRECTORY/ldap" '
				BEGIN { getline pw <pwfile }
				{ sub(/^\t+/, "") } # nix strips spaces from indented strings, not tabs
				/@LDAPUSERS@/ { print ENVIRON["USERS"]; next }
				{ gsub("@BINDPW@", pw); print }
			' ${ldapConfig} >"$conf.new"
			mv "$conf.new" "$conf"
		'';
	};

	# kino.cpli.dev still answers until the apps point at amartia.online
	services.caddy.virtualHosts.${kino} = {
		serverAliases = [ "kino.${config.networking.fqdn}" ];
		extraConfig = ''
			reverse_proxy 127.0.0.1:8096
		'';
	};
}
