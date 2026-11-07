{ config, lib, pkgs, ... }: let
	# ecdo (ἐκδίδωμι: to give out, publish): websites published at runtime.
	# each host is a nix profile in ${sites}/<host>/site whose generations
	# are store paths, and caddy serves whichever one it points at.
	state = "/var/lib/ecdo";
	sites = "${state}/sites";

	# sites must live under these; everything else gets no certificate
	zones = [ "amartia.online" "cpli.dev" ];
	keep = 5; # generations per host, for rollback
	limit = 1024 * 1024 * 1024; # bytes per upload
	ask = "127.0.0.1:9180";

	# a publish signed by a live cert goes to <site>, one signed by a preview
	# cert to preview.<site> until lux publishes it again. like fog-deploy,
	# the certs come from the running system
	certs = {
		live = [ ./certs/lux.asc ];
		preview = [ ./certs/phi.asc ];
	};

	# names with a vhost of their own, which would shadow a published site
	reserved = lib.filter (name: builtins.match "[a-z0-9.-]+" name != null)
		(lib.attrNames config.services.caddy.virtualHosts);

	# the shell shared by the ssh command and the import from /srv/http
	common = ''
		set -euf
		export PATH=${lib.makeBinPath (with pkgs; [
			coreutils gnutar sequoia-sqop config.nix.package
		])}
		export HOME=${state}
		say() { echo "ecdo: $*" >&2; }
		die() { say "$*"; exit 1; }

		# a site is a lowercase name in one of the zones, not a reserved one
		site() {
			case $1 in
			${lib.concatStringsSep "|" ([ "preview.*" ".*" "*." "*..*" "*[!a-z0-9.-]*" ] ++ reserved)}) return 1 ;;
			esac
			case $1 in
			${lib.concatMapStringsSep "|" (z: "${z}|*.${z}") zones}) return 0 ;;
			esac
			return 1
		}
		# a host is a site or its preview
		host() { site "''${1#preview.}"; }

		# add a directory to the store and make it the host's next generation
		put() {
			path=$(nix-store --add "$2")
			mkdir -p ${sites}/$1
			nix-env -p ${sites}/$1/site --set "$path"
			nix-env -p ${sites}/$1/site --delete-generations +${toString keep}
			say "$1 is $path"
		}
	'';

	verify = tier: "sqop verify --not-before \"$(stamp)\" \"$tmp/sig\" "
		+ "${lib.escapeShellArgs certs.${tier}} <\"$tmp/data\" 2>/dev/null";

	# the forced command of ecdo's ssh keys:
	#   ssh ecdo@lemma0 publish <site> <signature+tarball
	#   ssh ecdo@lemma0 list
	#   ssh ecdo@lemma0 rollback <host>
	command = pkgs.writeShellScript "ecdo" ''
		${common}
		set -- ''${SSH_ORIGINAL_COMMAND-}

		# the last publish's signing time; an older signature is a replay
		stamp() { cat ${state}/stamps/$target 2>/dev/null || echo 1970-01-01T00:00:00Z; }

		publish() {
			site "$1" || die "$1 is not a site under ${toString zones}"
			tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

			# an armored detached signature, then the tarball. bash reads a pipe
			# a byte at a time, so the tarball starts right after the last line
			while IFS= read -r line; do
				printf '%s\n' "$line" >>"$tmp/sig"
				[ "$line" = "-----END PGP SIGNATURE-----" ] && break
			done
			[ -s "$tmp/sig" ] || die "no signature"
			head -c ${toString (limit + 1)} >"$tmp/tar"
			[ "$(stat -c %s "$tmp/tar")" -le ${toString limit} ] ||
				die "larger than ${toString limit} bytes"

			# the site's name is signed too, so a signature can't be moved to
			# another site, and git's signed payloads never begin with "ecdo "
			{ printf 'ecdo %s\n' "$1"; cat "$tmp/tar"; } >"$tmp/data"
			# assignments run in order, so stamp already sees $target
			if target=$1 out=$(${verify "live"}); then :
			elif target=preview.$1 out=$(${verify "preview"}); then :
			else die "no good signature newer than the last publish"
			fi

			mkdir "$tmp/$1"
			tar -x -C "$tmp/$1" --no-same-owner --no-same-permissions <"$tmp/tar"
			put "$target" "$tmp/$1"
			echo "''${out%% *}" >${state}/stamps/$target
		}

		case ''${1-} in
		publish) [ $# -eq 2 ] || die "usage: publish <site>"; publish "$2" ;;
		list)
			set +f
			for d in ${sites}/*/; do
				[ -e "$d/site" ] || continue
				printf '%s %s\n' "$(basename "$d")" "$(readlink -f "$d/site")"
			done
			;;
		rollback)
			[ $# -eq 2 ] && host "$2" && [ -e ${sites}/$2/site ] ||
				die "usage: rollback <published host>"
			nix-env -p ${sites}/$2/site --rollback
			;;
		*) die "usage: publish <site> | list | rollback <host>" ;;
		esac
	'';

	# what used to be served from /srv/http, published once per host
	seed = {
		"cpli.dev" = "/srv/http/cpli.dev";
		"audit.cpli.dev" = "/srv/http/audit";
		"amartia.online" = "/srv/http/amartia.online";
	};
	import = pkgs.writeShellScript "ecdo-import" ''
		${common}
		${lib.concatStrings (lib.mapAttrsToList (host: dir: ''
			host ${host} || die "${host} is not a site"
			[ -e ${sites}/${host}/site ] || [ ! -d ${dir} ] || put ${host} ${dir}
		'') seed)}
	'';
in {
	users.groups.ecdo = {};
	users.users.ecdo = {
		isSystemUser = true;
		group = "ecdo";
		home = state;
		useDefaultShell = true; # sshd runs the forced command through it
		# lux's ssh keys may publish, but only signatures decide where to
		openssh.authorizedKeys.keys = map (key: ''restrict,command="${command}" ${key}'')
			(builtins.fromJSON (builtins.readFile ../users/keys.json)).lux;
	};

	# caddy only traverses these; the profiles' gc roots are nix's business
	systemd.tmpfiles.rules = [
		"d ${state} 0755 ecdo ecdo -"
		"d ${sites} 0755 ecdo ecdo -"
		"d ${state}/stamps 0700 ecdo ecdo -"
	];

	systemd.services.ecdo-import = {
		description = "publish what /srv/http held, once per host";
		wantedBy = [ "multi-user.target" ];
		after = [ "nix-daemon.socket" "systemd-tmpfiles-setup.service" ];
		serviceConfig = {
			Type = "oneshot";
			User = "ecdo";
			ExecStart = import;
		};
	};

	# one rule for every published host. certificates are issued on the first
	# visit, but only for hosts that ask says are published
	services.caddy.globalConfig = ''
		on_demand_tls {
			ask http://${ask}/
		}
	'';
	services.caddy.virtualHosts = {
		"https://".extraConfig = ''
			tls {
				on_demand
			}
			root * ${sites}/{host}/site
			file_server
		'';
		"http://${ask}" = {
			listenAddresses = [ "127.0.0.1" ];
			logFormat = null;
			extraConfig = ''
				@published {
					expression {query.domain}.matches("^[a-z0-9.-]+$")
					file {
						root ${sites}
						try_files {query.domain}/site/
					}
				}
				respond @published 200
				respond 404
			'';
		};
	};
}
