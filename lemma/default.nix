{ config, ... }: {
	imports = [
		./hardware.nix
		./http.nix
		./net.nix
		./dn42.nix
		./kino.nix
		./phi.nix
		./deploy.nix
		./id.nix
	];

	nix = {
		settings = {
			auto-optimise-store = true;
			trusted-users = [ "@wheel" ]; # fog deploy -l
			experimental-features = [ "nix-command" "flakes" ];
		};
		gc = {
			automatic = true;
			dates = "monthly";
			options = "--delete-old";
		};
	};

	disko.devices = builtins.fromJSON (builtins.readFile ./disko.json);

	boot.loader.systemd-boot.enable = true;
	boot.loader.efi.canTouchEfiVariables = true;

	crypt.secrets.cpli.text = ''
		-----BEGIN PGP MESSAGE-----

		wcFMA3eZGxD4Ook8ARAA1O+2vr2eeC2UnM1wWAMbIz7uIuO1tAmpO2w34M6JkAoj
		ssExMH/DjmR+12mJ3qA3lnUlIu/UtfvT1dTVnjrs4knUM0sWM81az1kXS94BNsSi
		zCGfIg39QlVfnB88gQ1qWIxvrVBqV7ZQCubB/CbU41takg8PTqSO5BbYPRHy8mAa
		Copkkq6xfFgWnl0faCp07+WMAGemMCQnrMmtRbw22TVERm1N35DLBGgAZ4yvYtxX
		kMTS0ATqsfgigWmE6jYHvEyEdPhwvCU84jc3APqLefB6dyhPtc8HKzm+7mBqqho1
		7W/nbvllGOfHNHcfgcQGQatNTGKN61MSD0eyFp/FYD3b8GqJPSXJa60cHZn+mcj7
		fqwT6iLWanIelbQsGFw+qJPdwJ09Zp7sdGvQ7WyT6jSN1x2/uiWf4J/guUManx6O
		VaIX723qSZFJwb/miRqQOEuDb1yJImge6rW1qhkOGy7z30Tgekjp+Xu+Adya2LY6
		lfh3bl9Ufrij+8jkpnLM6DMvfDbiLyza9FW/c1on4RFAEny2mHoCYRERmDz0dEUz
		s9OHOTdoRFaeP6fNBDT1CQYQPRfcS1N1KmsR2/vCHwOctQMX64o4AuH5tkDiEa7t
		9fSEeMbi/0RRUjSFd5cFdtl3LbNIbfUwSvqi3APfR4nMJm/1N2PUfdmmNzH7XBnB
		XgPhmLVO0u7S+xIBB0AcxCHkPGVmvhOqVzOMH3uu4V6FWxf0VBTkrSgq2QOpEDD3
		n0bGvBzRry5INwh6W+RW9JA0vNImh7q0Prf6gjjX7O2pdOQDReWyWbh1CBFvR5HS
		ewFufIZOZzgp3qssSMc9eoi778Ojgnv/KmSwxjJqJdA5LuPLgQgtQFfiT7eHXUG/
		/3nP0fc0aPvZuUz5tA+ak0U2mVTh5dJTd+oGM+mXgkWRhtVkptSEamNZMN74lww7
		4EOFdz+DC4zUXPLZQy316HSlXPqFUd73A9mk4Q==
		=vKCT
		-----END PGP MESSAGE-----
	'';

	users.users = {
		cpli = {
			extraGroups = [ "wheel" ];
			hashedPasswordFile = config.crypt.secrets.cpli.path;
			uid = 1000;
		};
		bunbun.uid = 1009;
		lux.extraGroups = [ "wheel" ];
	};

	services.openssh = {
		enable = true;
		settings.PasswordAuthentication = false;
	};

	system.stateVersion = "25.05"; # rtfm
}
