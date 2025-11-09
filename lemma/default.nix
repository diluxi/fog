{
	imports = [
		./hardware.nix
		./http.nix
	];

	nix = {
		settings = {
			auto-optimise-store = true;
			experimental-features = "nix-command flakes";
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

	users.users = {
		cpli = {
			extraGroups = [ "wheel" ];
			uid = 1000;
		};
		bunbun.uid = 1009;
	};

	networking = {
		useDHCP = false;
		hostName = "lemma0";
		fqdn = "cpli.dev";
	};

	systemd.network.enable = true;
	systemd.network.networks."10-wan" = {
		matchConfig.Name = "enp1s0";
		networkConfig.DHCP = "ipv4";
		address = [
			"2a01:4f8:c2c:e253::1/64"
		];
		routes = [
			{ Gateway = "fe80::1"; }
		];
	};

	services.openssh = {
		enable = true;
		settings.PasswordAuthentication = false;
	};

	system.stateVersion = "25.05"; # rtfm
}
