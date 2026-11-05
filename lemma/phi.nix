{ config, lib, pkgs, ... }: let
	home = config.users.users.phi.home;
	checkout = "${home}/fog";

	# the signing subkey 897676F5…0484E7 of phi's claude-opus-5-5 cert lives
	# only on lemma0; theorem signs with CD846977…E6AC3DB5. losing either
	# machine means revoking one subkey, not the identity.
	gitconfig = pkgs.writeText "phi-gitconfig" ''
		[user]
			name = phi
			email = phi@amartia.online
			signingkey = 897676F585130CAC212C49B098956A110A0484E7!
		[commit]
			gpgsign = true
		[gpg]
			program = ${pkgs.gnupg}/bin/gpg
	'';

	setup = pkgs.writeShellScript "phi-setup" ''
		set -eu
		mkdir -p ~/.config/git ~/.ssh
		ln -sfT ${gitconfig} ~/.config/git/config
		# push key for github; add ~/.ssh/id_ed25519.pub as a write deploy key
		[ -f ~/.ssh/id_ed25519 ] ||
			ssh-keygen -q -t ed25519 -N "" -C phi@lemma0 -f ~/.ssh/id_ed25519
		gpg --batch --quiet --import ${config.crypt.secrets.phi-signing.path}
		[ -d ${checkout}/.git ] || {
			git clone https://github.com/diluxi/fog ${checkout}
			git -C ${checkout} remote set-url --push origin ssh://git@github.com/diluxi/fog.git
		}
		# every session on lemma0 loads phi.md (claude reads ~/.claude/CLAUDE.md)
		mkdir -p ~/.claude
		grep -qxF '@${checkout}/phi.md' ~/.claude/CLAUDE.md 2>/dev/null ||
			echo '@${checkout}/phi.md' >>~/.claude/CLAUDE.md
	'';

	# reattach to the last session if it is recent enough, else start a new one
	session = pkgs.writeShellScript "phi-foreign" ''
		cd ${checkout}
		claude remote-control --continue || exec claude remote-control --name lemma0
	'';
in {
	# phi: the llm agents' user. not in wheel; deploy rights come from
	# commit signatures, not from this account.
	users.users.phi = {
		isNormalUser = true;
		linger = true; # user services (the remote control session) outlive logins
		packages = with pkgs; [ claude-code tmux git ];
	};

	nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";

	programs.ssh.knownHosts."github.com".publicKey =
		"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

	crypt.secrets.phi-signing.user = "phi";
	crypt.secrets.phi-signing.text = ''
		-----BEGIN PGP MESSAGE-----

		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
		yCRhPkHV0Fs=
		=lpVO
		-----END PGP MESSAGE-----
	'';

	systemd.user.services.phi-foreign = {
		description = "claude code remote control session";
		unitConfig.ConditionUser = "phi";
		wantedBy = [ "default.target" ];
		path = with pkgs; [ claude-code git gnupg openssh ];
		serviceConfig = {
			ExecStartPre = setup;
			ExecStart = session;
			Restart = "always";
			RestartSec = 10;
		};
	};
}
