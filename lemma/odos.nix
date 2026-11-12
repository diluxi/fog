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
in {
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
}
