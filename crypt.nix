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
		_crypt_previous=$(readlink ${dir} || true)
		_crypt_generation=$(basename "''${_crypt_previous:-0}")
		_crypt_failed=
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
		if (
			umask u=r,g=,o=
			printf %s "${text}" | ${bin} decrypt ${escapeShellArgs certs} >"$TMP_FILE"
		); then
			chmod ${mode} "$TMP_FILE"
			mv -f "$TMP_FILE" "$_true_path"
			[ "${path}" != "${dir}/${name}" ] && ln -sfT "${dir}/${name}" "${path}"
		else
			echo "[crypt] could not decrypt '${name}'" >&2
			rm -f "$TMP_FILE"
			_crypt_failed=1
		fi
	'';

	# a secret that fails to decrypt must not replace a working one: keep the
	# previous generation linked, drop the new one, and fail the activation
	# (false trips the activation script's ERR trap)
	cleanupAndLink = ''
		if [ -n "$_crypt_failed" ]; then
			echo "[crypt] keeping $_crypt_previous," \
				"dropping generation $_crypt_generation" >&2
			rm -rf "${mnt}/$_crypt_generation"
			_crypt_generation=$(basename "''${_crypt_previous:-0}")
			false
		else
			echo "[crypt] symlinking generation $_crypt_generation to ${dir}..."
			ln -sfT "${mnt}/$_crypt_generation" ${dir}
			if [ -n "$_crypt_previous" ]; then
				echo "[crypt] removing old secrets ($_crypt_previous)..."
				rm -rf "$_crypt_previous"
			fi
		fi
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
			services = mkOption {
				type = types.listOf types.str;
				default = [];
				description = ''
					Services that read the secret only when they start, and so
					restart when it changes.
				'';
			};
		};
	});
	generatedType = types.submodule ({ config, ... }: {
		options = {
			name = mkOption {
				type = types.str;
				default = config._module.args.name;
			};
			script = mkOption {
				type = types.lines;
				default = "openssl rand -hex 32 | tr -d '\\n' >$out";
				description = ''
					Writes the secret to $out, and may write more files beside it
					as $out.<suffix>. Runs once, as root, in a private directory,
					with coreutils, sed and openssl on its path.
				'';
			};
			path = mkOption {
				type = types.str;
				default = "${cfg.generatedDir}/${config.name}";
				readOnly = true;
			};
		};
	});

	# a secret is made in a temporary directory and moved into place whole,
	# so a failed script leaves nothing behind and runs again next time
	generateSecret = secret: with secret; ''
		if [ ! -e ${escapeShellArg path} ]; then
			echo "[crypt] generating '${name}'"
			_crypt_tmp=$(mktemp -d ${escapeShellArg cfg.generatedDir}/.new.XXXXXX)
			if (cd "$_crypt_tmp" && umask 077 && export out="$_crypt_tmp/${name}" &&
				PATH=${makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.openssl ]}:$PATH \
					${pkgs.bash}/bin/bash -euo pipefail -c ${escapeShellArg script} &&
				[ -s "$out" ]); then
				mv "$_crypt_tmp"/* ${escapeShellArg cfg.generatedDir}/
			else
				echo "[crypt] could not generate '${name}'" >&2
			fi
			rm -rf "$_crypt_tmp"
		fi
	'';
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

		generated = mkOption {
			type = types.attrsOf generatedType;
			default = {};
			description = ''
				Secrets made on the machine itself, once, and kept in
				generatedDir: for service internals that nobody needs to know and
				that are cheap to lose. Read them there to break glass.
			'';
		};
		generatedDir = mkOption {
			type = types.path;
			default = "/var/lib/crypt";
		};
	};

	config = mkMerge [ (mkIf (cfg.generated != {}) {
		system.activationScripts.cryptGenerate = {
			text = concatStringsSep "\n" ([
				"mkdir -p ${escapeShellArg cfg.generatedDir}"
				"chmod 0700 ${escapeShellArg cfg.generatedDir}"
			] ++ map generateSecret (attrValues cfg.generated));
			deps = [ "specialfs" ];
		};
	}) (mkIf (cfg.secrets != {}) {
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

		# the units embed a hash of the ciphertext, so a changed secret changes
		# them and the switch restarts them. re-encrypting an unchanged secret
		# restarts them too, since only the ciphertext is known at evaluation
		systemd.services = mkMerge (mapAttrsToList (_: secret:
			genAttrs secret.services (_: {
				restartTriggers = [ (builtins.hashString "sha256" secret.text) ];
			})) cfg.secrets);
	}) ];
}
