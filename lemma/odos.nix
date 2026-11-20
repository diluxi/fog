{ config, lib, pkgs, ... }: let
	odos = pkgs.callPackage ./odos/package.nix {};
	kino = "/srv/kino";
	video = "/srv/seed/video";
	# the shelf's trees, each linked into a library of kavita's in /srv/shelf
	# (lemma/shelf.nix)
	shelf = "/srv/shelf";
	shelves = { manga = "Manga"; comics = "Comics"; books = "Books"; };

	# finished torrents leave a marker here, which only says to run.
	# qbittorrent runs in airvpn's namespace, but has the host's /run
	spool = "/run/odos";
	torrentDone = pkgs.writeShellScript "torrent-done" ''
		: >${spool}/"$1"
	'';

	# the rules, as odos reads them: s-expressions
	lisp = s: "\"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s}\"";
	rule = path: r: "(${lisp path}"
		+ lib.optionalString (r.series != null) " :series ${lisp r.series}"
		+ lib.optionalString (r.film != null) " :film ${toString r.film}"
		+ lib.optionalString (r.show != null) (" :show ${toString r.show}"
			+ (if r.episode != null
				then " :episode (${toString r.episode.season} ${toString r.episode.number})"
				else " :episodes (${lib.concatMapStrings (e:
					"(${toString e.from} ${if e.to == null then "nil" else toString e.to} ${toString e.season} ${toString e.offset} ${if e.parts then "t" else "nil"})") r.episodes})"))
		+ lib.optionalString r.ignore " :ignore t"
		+ lib.optionalString r.prefer " :prefer t"
		+ ")\n";
	rules = pkgs.writeText "odos-rules" (lib.concatStrings (lib.mapAttrsToList rule config.odos.rules));
in {
	imports = [ ./odos-rules.nix ];

	options.odos.rules = lib.mkOption {
		description = ''
			Where a torrent's folders and files are said to be, for what no name
			says well enough: a path under ${video}, and the tmdb film it is, or
			the tmdb show whose seasons its episodes are; or a path under
			/srv/seed that starts with a shelf's tree (manga/, comics/, books/),
			and the series its files are. The longest path that holds a file is
			its rule; a video's holds its subtitles too. `ignore` keeps what it
			holds out, and `prefer` makes its copies win over any other copy of
			the same episode or film. `odos rules --nix` prints the rules made
			with odos's command line in this form.
		'';
		default = {};
		type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
			options = {
				film = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
				series = lib.mkOption {
					description = "The series a shelf's files are, as its folder in kavita's library.";
					type = lib.types.nullOr lib.types.str;
					default = null;
				};
				show = lib.mkOption {
					description = "The show, its seasons and episodes as the names say, or as `season` or `episodes` or `episode` say.";
					type = lib.types.nullOr lib.types.ints.positive;
					default = null;
				};
				episode = lib.mkOption {
					description = "The one episode a file of `show` is.";
					type = lib.types.nullOr (lib.types.submodule {
						options = {
							season = lib.mkOption { type = lib.types.ints.unsigned; };
							number = lib.mkOption { type = lib.types.ints.unsigned; };
						};
					});
					default = null;
				};
				ignore = lib.mkOption {
					description = "Never linked: openings, endings, extras.";
					type = lib.types.bool;
					default = false;
				};
				prefer = lib.mkOption {
					description = "Its copies win over any other of the same episode or film.";
					type = lib.types.bool;
					default = false;
				};
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

		# qbittorrent's "run external program on torrent finished", with the
		# torrent's id (%K: its hash, v1 or v2)
		services.qbittorrent.serverConfig.AutoRun = {
			enabled = true;
			program = "${torrentDone} %K";
		};
		# qbittorrent makes the markers, odos (in kino) takes them away
		systemd.tmpfiles.rules = [ "d ${spool} 2770 qbittorrent kino -" ];

		systemd.services.odos = {
			description = "link finished torrents into kino's libraries";
			unitConfig.RequiresMountsFor = [ kino video shelf ]
				++ map (tree: "/srv/seed/${tree}") (lib.attrNames shelves);
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
				] + lib.concatStrings (lib.mapAttrsToList (tree: library:
					" --shelf ${lib.escapeShellArg "/srv/seed/${tree}:${shelf}/${library}"}") shelves);
				LoadCredential = [ "api:${config.crypt.generated.jellyfin-api.path}" ];
				DynamicUser = true;
				# kino may write /srv/kino and read /srv/seed/video, shelf write
				# /srv/shelf and read the shelf's trees
				SupplementaryGroups = [ "kino" "shelf" ];
				StateDirectory = "odos";
				ReadOnlyPaths = [ "/srv/seed" ];
				ReadWritePaths = [ kino shelf spool ];
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
