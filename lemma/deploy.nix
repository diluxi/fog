{ config, lib, pkgs, ... }: let
	url = "https://github.com/diluxi/fog";
	branch = "dev";
	state = "/var/lib/fog-deploy";

	# the first deploy must descend from this commit; later ones from the last
	# switched commit, so an older signed tip can't roll lemma0 back
	root = "5718fcebd36c73312c515478a6f009609fe561e8";

	# certs are read from the running system, never from the incoming commit.
	# a tip signed by a switch cert is switched to; one signed by a test cert
	# only tested, so a reboot reverts it until a human ratifies it.
	# TODO lux: add your cert here. until then the switch tier is empty and
	# only test deploys can happen.
	certs = {
		switch = [ ];
		test = [ ./certs/phi.asc ];
	};

	sqop = "${pkgs.sequoia-sqop}/bin/sqop";
	verify = tier: if certs.${tier} == [ ] then "false" else
		"${sqop} verify \"$tmp/sig\" ${lib.escapeShellArgs certs.${tier}} <\"$tmp/data\" >/dev/null";

	deploy = pkgs.writeShellScript "fog-deploy" ''
		set -eu
		repo=${state}/repo.git
		say() { echo "fog-deploy: $*"; }

		[ -d $repo ] || git init -q --bare $repo
		git -C $repo fetch -q --no-tags ${url} "+refs/heads/${branch}:refs/heads/${branch}"
		tip=$(git -C $repo rev-parse --verify "refs/heads/${branch}^{commit}")

		switched=$(cat ${state}/switched 2>/dev/null || echo ${root})
		[ "$tip" = "$switched" ] && { say "$tip is switched to already"; exit 0; }
		for f in tested failed; do
			[ "$(cut -d' ' -f1 ${state}/$f 2>/dev/null)" = "$tip" ] &&
				{ say "$tip is $f already"; exit 0; }
		done

		git -C $repo merge-base --is-ancestor "$switched" "$tip" ||
			{ say "$tip does not descend from $switched, refusing"; exit 1; }

		tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
		# split the commit object into its signature and the signed payload
		git -C $repo cat-file commit "$tip" | awk -v sig="$tmp/sig" -v data="$tmp/data" '
			/^gpgsig / { s = 1; sub(/^gpgsig /, ""); print >sig; next }
			s && /^ / { sub(/^ /, ""); print >sig; next }
			{ s = 0; print >data }'
		[ -s "$tmp/sig" ] || { say "$tip is unsigned, refusing"; exit 1; }

		if ${verify "switch"}; then action=switch
		elif ${verify "test"}; then action=test
		else say "$tip has no good signature from a trusted cert, refusing"; exit 1
		fi

		mkdir "$tmp/src"
		git -C $repo archive "$tip" | tar -x -C "$tmp/src"
		sys=$(nix-build "$tmp/src" -A config.system.build.toplevel --no-out-link)
		say "$action $tip: $sys"

		# activate as fog-switch, the unit ./fog deploy uses, so the two lock
		# each other out. this unit has restartIfChanged off and survives it.
		systemctl is-active -q fog-switch &&
			{ say "an activation is still running, retrying later"; exit 1; }
		systemctl reset-failed fog-switch 2>/dev/null || true
		profile=
		[ $action = switch ] &&
			profile="nix-env -p /nix/var/nix/profiles/system --set $sys &&"
		if systemd-run --unit=fog-switch --wait --quiet --service-type=exec \
			/bin/sh -c "$profile exec $sys/bin/switch-to-configuration $action"
		then
			case $action in
			switch) echo "$tip" >${state}/switched; rm -f ${state}/tested ;;
			test) echo "$tip $sys" >${state}/tested ;;
			esac
		else
			# don't retry a failed activation every tick; a new commit will
			echo "$tip" >${state}/failed
			say "activation failed, see journalctl -u fog-switch"; exit 1
		fi
	'';
in {
	systemd.services.fog-deploy = {
		description = "deploy the signed tip of fog's ${branch} branch";
		startAt = "*:0/5";
		restartIfChanged = false; # it may be the one switching
		path = with pkgs; [ coreutils gawk git gnutar config.nix.package systemd ];
		environment.HOME = state;
		serviceConfig = {
			Type = "oneshot";
			StateDirectory = "fog-deploy";
			ExecStart = deploy;
		};
	};

	# phi may start fog-deploy, and nothing else
	security.polkit.extraConfig = ''
		polkit.addRule(function(action, subject) {
			if (action.id == "org.freedesktop.systemd1.manage-units" &&
					action.lookup("unit") == "fog-deploy.service" &&
					action.lookup("verb") == "start" &&
					subject.user == "phi") {
				return polkit.Result.YES;
			}
		});
	'';
}
