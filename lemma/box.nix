{ config, lib, pkgs, ... }: let
	# witness0, the storage box (fog.tofu), through its srv subaccount. both
	# files come from `./fog witness` after `./fog tofu apply`
	ready = builtins.pathExists ./witness0.json && builtins.pathExists ./witness0.asc;
	box = if ready then builtins.fromJSON (builtins.readFile ./witness0.json)
		else throw "lemma/witness0.{json,asc} are missing: ./fog tofu apply, then ./fog witness";
	share = "//${box.server}/${box.username}";
	credentials = config.crypt.secrets.witness0-srv.path;

	# smb 3.1.1, encrypted (seal) even inside hetzner's network. symlinks
	# are stored as small files on the box (mfsymlinks), which is how kino
	# links to what seed holds. a box that's down doesn't stop the boot
	common = [
		"credentials=${credentials}"
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
	# the subaccount's username and generated password, as a cifs
	# credentials file
	crypt.secrets.witness0-srv.text = if ready then builtins.readFile ./witness0.asc
		else box;

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
		description = "directories on witness0 for /srv";
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
				"credentials=${credentials}" "vers=3.1.1" "seal"
			]}
			trap 'umount "$dir"; rmdir "$dir"' EXIT
			mkdir -p "$dir/seed/video" "$dir/kino"
		'';
	};
}
