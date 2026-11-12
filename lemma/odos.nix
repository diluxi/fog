{ config, lib, pkgs, ... }: let
	odos = pkgs.callPackage ./odos/package.nix {};
	kino = "/srv/kino";
	video = "/srv/seed/video";

	# finished torrents leave a marker here, which only says to run. transmission
	# runs in airvpn's namespace with its own root, but has the host's /run
	spool = "/run/odos";
	torrentDone = pkgs.writeShellScript "torrent-done" ''
		: >${spool}/"$TR_TORRENT_HASH"
	'';

	# the rules, as odos reads them: s-expressions
	lisp = s: "\"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s}\"";
	rule = path: r:
		if r.film != null then "(${lisp path} :film ${toString r.film})\n"
		else "(${lisp path} :show ${toString r.show} :episodes (${lib.concatMapStrings (e:
			"(${toString e.from} ${if e.to == null then "nil" else toString e.to} ${toString e.season} ${toString e.offset} ${if e.parts then "t" else "nil"})") r.episodes}))\n";
	rules = pkgs.writeText "odos-rules" (lib.concatStrings (lib.mapAttrsToList rule config.odos.rules));
in {
	imports = [ ./odos-rules.nix ];

	options.odos.rules = lib.mkOption {
		description = ''
			Where a torrent's folders and files are said to be, for what no name
			says well enough: a path under ${video}, and the tmdb film it is, or
			the tmdb show whose seasons its episodes are. The longest path that
			holds a file is its rule.
		'';
		default = {};
		type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
			options = {
				film = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
				show = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
				season = lib.mkOption {
					description = "The season all its episodes are, shifted by offset.";
					type = lib.types.nullOr lib.types.ints.unsigned;
					default = null;
				};
				offset = lib.mkOption { type = lib.types.int; default = 0; };
				episodes = lib.mkOption {
					description = ''
						Episode n of the files, from `from` to `to` (or on), is episode
						n+offset of `season`; or with `parts`, part n-from+1 of the one
						episode from+offset, which Jellyfin plays as one.
					'';
					type = lib.types.listOf (lib.types.submodule {
						options = {
							from = lib.mkOption { type = lib.types.ints.unsigned; default = 1; };
							to = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; default = null; };
							season = lib.mkOption { type = lib.types.ints.unsigned; };
							offset = lib.mkOption { type = lib.types.int; default = 0; };
							parts = lib.mkOption { type = lib.types.bool; default = false; };
						};
					});
					default = lib.optional (config.season != null) { inherit (config) season offset; };
				};
			};
		}));
	};

	config = {
		# jellyfin's libraries are what odos makes (lemma/kino.nix)
		kino.libraries = {
			TV = { type = "tvshows"; paths = [ "${kino}/TV" ]; };
			Films = { type = "movies"; paths = [ "${kino}/Films" ]; };
		};

		services.transmission.settings = {
			script-torrent-done-enabled = true;
			script-torrent-done-filename = torrentDone;
		};
		# transmission makes the markers, odos (in kino) takes them away
		systemd.tmpfiles.rules = [ "d ${spool} 2770 transmission kino -" ];

		systemd.services.odos = {
			description = "link finished torrents into kino's libraries";
			unitConfig.RequiresMountsFor = [ kino video ];
			after = [ "jellyfin.service" ];
			serviceConfig = {
				Type = "oneshot";
				ExecStart = lib.escapeShellArgs [
					(lib.getExe odos)
					"--video" video
					"--links" kino
					"--shows" "${kino}/TV"
					"--films" "${kino}/Films"
					"--state" "/var/lib/odos"
					"--spool" spool
					"--key-file" "%d/api"
				"--rules" rules
				];
				LoadCredential = [ "api:${config.crypt.generated.jellyfin-api.path}" ];
				DynamicUser = true;
				# kino may write /srv/kino and read /srv/seed/video
				SupplementaryGroups = [ "kino" ];
				StateDirectory = "odos";
				ReadOnlyPaths = [ "/srv/seed" ];
				ReadWritePaths = [ kino spool ];
				# while jellyfin is away, what it should hear waits in
				# /var/lib/odos/pending, and odos tries again in a minute
				Restart = "on-failure";
				RestartSec = "1min";
				ProtectSystem = "strict";
				ProtectHome = true;
				PrivateTmp = true;
				NoNewPrivileges = true;
				RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
			};
		};
		systemd.paths.odos = {
			wantedBy = [ "multi-user.target" ];
			pathConfig.DirectoryNotEmpty = spool;
		};
		# and daily, for what's put into the seed tree by hand
		systemd.timers.odos = {
			wantedBy = [ "timers.target" ];
			timerConfig = {
				OnBootSec = "5min";
				OnCalendar = "daily";
			};
		};
	};
}
