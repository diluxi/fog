{ config, ... }: {
	imports = [
		./hardware.nix
		./http.nix
		./ecdo.nix
		./net.nix
		./dn42.nix
		./kino.nix
		./phi.nix
		./deploy.nix
		./id.nix
		./lldap-accounts.nix
		./vault.nix
		./mail.nix
		./pulse.nix
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

	crypt.certificatePaths = [ "/etc/lemma0.sec" ];
	crypt.secrets.cpli.text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0Db2OHxOtPTMHmd6BwBzh5k0tjP
		sVbUqutIrzlbxUDELjC6abFSow/y4/pSWveWLlnuhpGu8Dc85Z9SkLAuftz5FmQg
		bgqMTa0j14WcYWDqsYTBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQHD1g2kR
		VONHjoCO9yBysdsz2qyjBF7c00s5B34guUlBMFRNjtdjOznlEXadKKfIKuWJouxb
		Gj99OVWkuSihSho762PGHeqPtCaAq10Eveo5yNKeAgkCBmbKKH/wzrT40M8GIxAo
		CJ/Q80IafWh0UH2ZwM0ZC2Qv8Whxvly13OOIKsIjt63+AVxqv8cCe05ZyyVBmNl3
		h9pbLwpxSHXmAI2Db0eaXfDY7OmMxeIf7jDajQ79rReWeCPA7VskYKk3YK58Fb7S
		5STTFbjS3bWWglFK6xFYUPv0xkWfYca/it25bEZDKK5ANjl91mgjEC++ONg=
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
