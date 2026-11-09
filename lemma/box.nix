{ config, lib, pkgs, ... }: let
	# witness0, the storage box (fog.tofu), through its srv subaccount. the
	# files come from `./fog witness` after `./fog tofu apply`
	ready = lib.all builtins.pathExists [ ./witness0.json ./witness0.asc ./witness0-key.asc ];
	box = if ready then builtins.fromJSON (builtins.readFile ./witness0.json)
		else throw "lemma/witness0{.json,.asc,-key.asc} are missing: ./fog tofu apply, then ./fog witness";
	share = "//${box.server}/${box.username}";
	credentials = config.crypt.secrets.witness0-srv.path;
	key = config.crypt.secrets.witness0-key.path;

	# what's on the box is encrypted (gocryptfs), so it shows hetzner neither
	# names nor contents; it does show sizes and the shape of the trees. each
	# tree is its own gocryptfs directory under srv/cipher/ on the box, its
	# own cifs mount under ${cipher}, where only root reaches, and its own
	# plain view under /srv. a gocryptfs view shows the modes of the mount
	# beneath it, which cifs fixes per mount, so the modes are set there and
	# the owners on top (force_owner)
	cipher = "/var/lib/witness0";
	trees = {
		# what transmission seeds, of every kind. its directories can be
		# passed through (771), so jellyfin reaches video/ and lists nothing
		seed = { at = "/srv/seed"; owner = "${toString uid.transmission}:${toString gid.seed}";
			modes = [ "file_mode=0660" "dir_mode=0771" ]; };
		# what kino links to, readable by kino
		video = { at = "/srv/seed/video"; owner = "${toString uid.transmission}:${toString gid.kino}";
			modes = [ "file_mode=0640" "dir_mode=0750" ]; };
		# jellyfin's libraries, mostly links into seed/video
		kino = { at = "/srv/kino"; owner = "0:${toString gid.kino}";
			modes = [ "file_mode=0660" "dir_mode=0770" ]; };
	};
	uid.transmission = config.ids.uids.transmission;
	# fixed, since force_owner takes numbers: the ones nixos gave these
	# groups when they were first made, which it won't change afterwards
	gid = { seed = 983; kino = 984; };

	# smb 3.1.1, encrypted (seal) on the wire too. symlinks are stored as
	# small files (mfsymlinks); gocryptfs keeps its own symlinks that way,
	# which is how kino links into video. a box that's down doesn't stop the
	# boot
	cifs = name: t: {
		device = "${share}/cipher/${name}";
		fsType = "cifs";
		options = [
			"credentials=${credentials}"
			"vers=3.1.1" "seal" "mfsymlinks" "iocharset=utf8"
			"uid=0" "gid=0"
			"_netdev" "nofail" "x-systemd.mount-timeout=30s"
			"x-systemd.requires=witness0-dirs.service" "x-systemd.after=witness0-dirs.service"
		] ++ t.modes;
	};
	plain = name: t: {
		device = "${cipher}/${name}";
		fsType = "fuse.gocryptfs";
		options = [
			# mount hands gocryptfs everything but nofail, and gocryptfs refuses
			# what it doesn't know, like _netdev. the cifs mount beneath has it
			"passfile=${key}" "allow_other" "force_owner=${t.owner}" "nofail"
			"x-systemd.requires-mounts-for=${cipher}/${name}"
			"x-systemd.requires=witness0-init.service" "x-systemd.after=witness0-init.service"
		];
	};
in {
	# the subaccount's username and generated password, as a cifs
	# credentials file
	crypt.secrets.witness0-srv.text = if ready then builtins.readFile ./witness0.asc else box;
	# gocryptfs' password. losing it loses everything on the box: it lives
	# here, encrypted to lemma0 and lux, and nowhere else
	crypt.secrets.witness0-key.text = if ready then builtins.readFile ./witness0-key.asc else box;

	boot.supportedFilesystems = [ "cifs" ];
	system.fsPackages = [ pkgs.gocryptfs pkgs.fuse3 ];

	users.groups.seed.gid = gid.seed;
	users.groups.kino.gid = gid.kino;
	users.users.lux.extraGroups = [ "seed" "kino" ];
	users.users.jellyfin.extraGroups = [ "kino" ];

	# traversable, so the node exporter can stat the mounts beneath; what
	# they hold is ciphertext, owned by root
	systemd.tmpfiles.rules = [ "d ${cipher} 0711 root root -" ];

	fileSystems = lib.mapAttrs' (name: t: lib.nameValuePair "${cipher}/${name}" (cifs name t)) trees
		// lib.mapAttrs' (name: t: lib.nameValuePair t.at (plain name t)) trees;

	# a mount of a directory needs it to exist on the box first. the plain
	# directories the first version of this made go, if they're still empty
	systemd.services.witness0-dirs = {
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
			mount -t cifs ${share} "$dir" -o credentials=${credentials},vers=3.1.1,seal
			trap 'umount "$dir"; rmdir "$dir"' EXIT
			mkdir -p ${lib.concatMapStringsSep " " (n: "\"$dir/cipher/${n}\"") (lib.attrNames trees)}
			rmdir "$dir/seed/video" "$dir/seed" "$dir/kino" 2>/dev/null || true
		'';
	};

	# each tree becomes a gocryptfs directory the first time, with the key
	systemd.services.witness0-init = {
		description = "gocryptfs directories on witness0";
		unitConfig.RequiresMountsFor = map (n: "${cipher}/${n}") (lib.attrNames trees);
		path = [ pkgs.gocryptfs ];
		serviceConfig = {
			Type = "oneshot";
			RemainAfterExit = true;
		};
		script = lib.concatMapStrings (n: ''
			if [ ! -e ${cipher}/${n}/gocryptfs.conf ]; then
				echo "making ${n} a gocryptfs directory"
				gocryptfs -init -q -passfile ${key} ${cipher}/${n}
			fi
		'') (lib.attrNames trees);
	};
}
