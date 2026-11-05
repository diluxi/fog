{
	config,
	lib,
	pkgs,
	...
}: with lib; let
	cfg = config.crypt;

	bin = cfg.sopBin;
	dir = cfg.cryptDir;
	mnt = cfg.cryptMountPoint;
	certs = cfg.certificatePaths;

	newGeneration = ''
		_crypt_generation=$(basename "$(readlink ${dir} || echo 0)")
		(( ++_crypt_generation ))
		echo '[crypt] creating new generation in ${mnt}/'"$_crypt_generation"
		mk () { mkdir -p "$1"; chmod 0751 "$1"; }
		mk "${mnt}"
		grep -q "${mnt} ramfs" /proc/mounts ||
			mount -t ramfs none "${mnt}" -o nodev,nosuid,mode=0751
		mk "${mnt}/$_crypt_generation"
	'';

	chownMountPoint = ''chown :keys "${mnt}" "${mnt}/$_crypt_generation"'';

	installSecret = secret: with secret; ''
		_true_path="${mnt}/$_crypt_generation/${name}"
		echo "decrypting '${name}' to '$_true_path'…"
		TMP_FILE="$_true_path.tmp"
		mkdir -p "$(dirname "$_true_path")"
		[ "${path}" != "${dir}/${name}" ] && mkdir -p "$(dirname "${path}")"
		(
			umask u=r,g=,o=
			printf %s "${text}" | ${bin} decrypt ${escapeShellArgs certs} >"$TMP_FILE"
		)
		chmod ${mode} "$TMP_FILE"
		mv -f "$TMP_FILE" "$_true_path"
		[ "${path}" != "${dir}/${name}" ] && ln -sfT "${dir}/${name}" "${path}"
	'';

  cleanupAndLink = ''
    echo "[crypt] symlinking new secrets to ${dir} (generation $_crypt_generation)..."
    ln -sfT "${mnt}/$_crypt_generation" ${dir}

    (( _crypt_generation > 1 )) && {
    echo "[crypt] removing old secrets (generation $(( _crypt_generation - 1 )))..."
    rm -rf "${mnt}/$(( _crypt_generation - 1 ))"
    }
  '';

  installSecrets = builtins.concatStringsSep "\n" (
    [ "echo '[crypt] decrypting secrets...'" ]
    ++ (map installSecret (builtins.attrValues cfg.secrets))
    ++ [ cleanupAndLink ]
  );

  chownSecret = secret: with secret; ''
		_true_path="${mnt}/$_crypt_generation/${name}"
    chown ${user}:${group} "$_true_path"
  '';

  chownSecrets = builtins.concatStringsSep "\n" (
    [ "echo '[crypt] chowning...'" ]
    ++ [ chownMountPoint ]
    ++ (map chownSecret (builtins.attrValues cfg.secrets))
  );

	users = config.users.users;
	secretType = types.submodule ({ config, ... }: {
		options = {
			name = mkOption {
				type = types.str;
				default = config._module.args.name;
			};
			text = mkOption {
				type = types.str;
				description = "Encrypted secret's OpenPGP Message.";
			};
			path = mkOption {
				type = types.str;
				default = "${dir}/${config.name}";
				description = "Decrypted secret's installation path.";
			};
			mode = mkOption {
				type = types.str;
				default = "0400";
				description = ''
					Permissions mode of the decrypted secret in a format understood by chmod.
				'';
			};
			user = mkOption {
				type = types.str;
				default = "0";
				description = "Decrypted secret's user.";
			};
			group = mkOption {
				type = types.str;
				default = users.${config.user}.group or "0";
				description = "Decrypted secret's group.";
			};
		};
	});
in {
	options.crypt = {
		sopBin = mkOption {
			type = types.str;
			default = "${pkgs.sequoia-sqop}/bin/sqop";
			description = ''
				Stateless OpenPGP Command Line Interface executable to use
			'';
		};
		certificatePaths = mkOption {
			type = types.listOf types.path;
			default = [ "/etc/crypt.sec" ];
			description = ''
				PGP key paths to be used as certificates in sop decryption.
			'';
		};
		secrets = mkOption {
			type = types.attrsOf secretType;
			default = {};
			description = "Attrset of secrets";
		};
		cryptDir = mkOption {
			type = types.path;
			default = "/run/crypt";
			description = "Folder where secrets are symlinked to";
		};
		cryptMountPoint = mkOption {
			type = types.path;
			default = "/run/crypt.d";
		};
	};

	config = mkIf (cfg.secrets != {}) {
		# FIXME replace with sysusers setup
		system.activationScripts = {
			cryptNewGeneration = {
				text = newGeneration;
				deps = [ "specialfs" ];
			};
			cryptInstall = {
				text = installSecrets;
				deps = [ "cryptNewGeneration" "specialfs" ];
			};
			users.deps = [ "cryptInstall" ];
			cryptChown = {
				text = chownSecrets;
				deps = [ "users" "groups" ];
			};
			crypt = { text = ""; deps = [ "cryptChown" ]; };
		};
	};
}
