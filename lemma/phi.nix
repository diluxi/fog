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

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0AacD4K6TInbLjVKlKKDzM1JeMH
		/6x3y8Wbwvur4V/AUDDr/Ql4/72QC7XRm42Bh+c9kG/GJzAIWbIYM++A2Cw1UulW
		clmpJAgYOfj7qPYMpjTBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQIYCvmPr
		UkL6o1ktBtmt/z66kxqmGq0rcnpgWY7EXWYPMN7OIvenKXBDfa4dWO7NQyZDLABK
		z8YVY+IXu/adfxYdO9WXBNY6gonJpJ7YH3St/9LDhgIJAgaCIOjVjDQUjX6G5veb
		o+XaN9kSECb/OjTvRrh2HwIGpe/2A3DdY6BmQnl5yaXTj4apSFCGNn0+xpzMc3lF
		eA/xLbXBc+MybT0RouHHt/r3o4mhYQzSvQGKEE+qLsjqVMjskJZC87+APEJSgfwn
		KpfilRZdKePgnTQUNyIBWp9tnJIDgu/ma1VHczn6eU4qiSabDJewzcj5qOb9Ke1X
		gGui4b1CbxkEczwe9R4ba7z/U47wfxzGHZ2Gmc6lDmqfgdHuwfpbOeSWgp4ezEGx
		SNPqBhai4hl+Ryd2RNdtUxjN6ejolQfJG+ploXv4GOnlqztcND29Pzbg7SN7ti8q
		XW2jmx6UhuwIqDMJ8B9mro+zAaNwHCsbvUWrsPtyDlIC8cGV7uWQ1P0Bcc2oo7bt
		EvzCW+A+7ItRLCwlBA2PxHZ1klYveENCZf2uBifjgFsw1NO3ylA5u4DDFTbIsm7S
		H/DsrkrJyqVWAfcT+flf28IKvMliH6C8yF88xOYMPnAyj85tDD9IoNUTr8QEVFkl
		zijU2JrwwZHgiBREg9koLc/SMkMsXtYpzIhUXvZ7Ltci9bnDqWS1hwsswEPzmoPc
		71IJ31RnQp/fGuOdm3Jap0bqizI5+VY5kszzqpPlIpnTcMq9OwIGs62Qa598qV0Y
		dpTCX9GNoN/negfEe5nzX1eXtzGiTHnEvl17dGbfZSsBiD6T++9iz9MfJW8XutUd
		6K0fwA34Q7P9dgjxVA7pPsy3N8sndQzDPLKG+iP1O3aEe0XwUrtOJ+7H2GnocKpP
		62sPX+EeDOQu8VucdzqRN2LypuWhMUXdN/W7Fkxd0V2bDalmzWGCBAjYpt6fzbYI
		R4RGDzUsVagmoy+IJmSyJsStkxTSnT7WoIttEoe7yST1oKm3pVWLddw7488Wc4Nw
		eIE8FR13QE/EJuiTYPh5EmQ3vdKZQ4m0NVxbtW8JDfT/yqEHhIG2NbJEm90n/jIB
		tkr4zppIbq+gv0hZlwpcrFdidIN1sn9OhJENSMXWavN1fvRsaCNh5dcx2JxVMmQH
		djkYgmtErOfpVMJ+4ysrS3iyUHGWRTsORxn6vcdPuB+y8np80vxODpMDmud8Lpf4
		zlDGO3T6KNw+5TVJjmsq/Zfu8Thh0ZqBxjQnw9mT91ctNDaM7LKqzNZiQZB5uP2u
		MAKq5Ja2F6SCNTgtcxvct07Y9/qqdKrxsV7EZNQa36KBXC4AU3W+wbZAvOYpLEKx
		FL2cG4EllTNUjWeLPVtiB3WWUiznQ8mfQq9Vg/U7rsjKgXU4Ej4AwGNIPpe6TZTo
		ZsQBOIPcmm7tMYhI0R/NYnSRY1aTenJGKjwsvyqHQXAfSvcflUNHwi3Qdh/O1ljv
		3531uFatIu37A7PJy2pg3jCLJnWZiQS9iAbE9chGnEl1TY4mOV0trd8LicFnYINf
		14+3BxJrz8voDncCijf46uJVtXxU
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
