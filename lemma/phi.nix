{ lib, pkgs, ... }: {
	# phi: the llm agents' user. not in wheel; deploy rights come from
	# commit signatures, not from this account.
	users.users.phi = {
		isNormalUser = true;
		linger = true; # user services (the remote control session) outlive logins
		packages = with pkgs; [ claude-code tmux git ];
	};

	nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
}
