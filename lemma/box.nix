{ config, lib, pkgs, ... }: let
	# the storage box's srv subaccount (fog.tofu), from `tofu output storage_box_srv`
	box = todo "box.server and box.username" ''
		tofu apply, then fill both in from `tofu output storage_box_srv`'';
	share = "//${box.server}/${box.username}";
	credentials = config.crypt.secrets.box-srv.path;

	# placeholder until the value is filled in
	todo = name: how: throw ''
		${name} is missing.
			${how}
	'';

	# smb 3.1.1, encrypted (seal) even inside hetzner's network. symlinks
	# are stored as small files on the box (mfsymlinks), which is how kino
	# links to what seed holds. a box that's down doesn't stop the boot
	common = [
		"credentials=${credentials}"
		"username=${box.username}"
		"vers=3.1.1" "seal" "mfsymlinks" "iocharset=utf8"
		"_netdev" "nofail" "x-systemd.mount-timeout=30s"
		"x-systemd.requires=box-dirs.service" "x-systemd.after=box-dirs.service"
	];
	# cifs shows one owner and one mode per mount, so each tree is its own
	# mount, with its own
	mount = dir: perms: {
		device = "${share}/${dir}";
		fsType = "cifs";
		options = common ++ perms;
	};
in {
	# the subaccount's password, as a cifs credentials file
	crypt.secrets.box-srv.text = todo "crypt.secrets.box-srv" ''
		printf 'password=%s\n' "$the_subaccount_password" | sqop encrypt \
			lemma/certs/lemma0.asc lemma/certs/lux.asc'';

	boot.supportedFilesystems = [ "cifs" ];

	# /srv/seed: what transmission seeds, of every kind. its directories can
	# be passed through (771), so jellyfin reaches video/ without listing
	# anything else. /srv/seed/video: what kino links to, readable by kino.
	# /srv/kino: jellyfin's libraries, of links into seed/video mostly
	users.groups.seed = {};
	users.groups.kino = {};
	users.users.lux.extraGroups = [ "seed" "kino" ];
	users.users.jellyfin.extraGroups = [ "kino" ];

	fileSystems."/srv/seed" = mount "seed"
		[ "uid=transmission" "gid=seed" "file_mode=0660" "dir_mode=0771" ];
	fileSystems."/srv/seed/video" = mount "seed/video"
		[ "uid=transmission" "gid=kino" "file_mode=0640" "dir_mode=0750" ];
	fileSystems."/srv/kino" = mount "kino"
		[ "uid=root" "gid=kino" "file_mode=0660" "dir_mode=0770" ];

	# a mount of a directory needs it to exist on the box first
	systemd.services.box-dirs = {
		description = "directories on the storage box for /srv";
		after = [ "network-online.target" ];
		wants = [ "network-online.target" ];
		path = with pkgs; [ cifs-utils util-linux coreutils ];
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
		};
		script = ''
			dir=$(mktemp -d)
			mount -t cifs ${share} "$dir" -o ${lib.concatStringsSep "," [
				"credentials=${credentials}" "username=${box.username}"
				"vers=3.1.1" "seal"
			]}
			trap 'umount "$dir"; rmdir "$dir"' EXIT
			mkdir -p "$dir/seed/video" "$dir/kino"
		'';
	};
}
