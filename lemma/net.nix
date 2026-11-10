{ config, ... }: {
	crypt.secrets.wg.user = "systemd-network";
	crypt.secrets.wg.text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0AqaItJ/O5bghVYxGZMPZQ5Csgi
		Hm7+AlV1ZVRFkQ+qUjC/e+5yq/BfvzTWz3VfuGAklOrbpTN8/MrjlIfOFPe4anuJ
		9T3UvjCHCAwivzEY05nBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQLvVijBG
		hC/sKf1DBRk8dmlOoBRPtuAIZnsPvsLq5o9zMCBA/j+YmFpiuS0fZJS8yT/6fxrR
		q9wFeH9Ahed1qGBHwIk/b9FaL0ivGNRKCRFJ2NJ6AgkCBiz07kq7njUvWu8Yb2j6
		n6OXa4yFZA63KAe9yramuF8QGACM0QEeB2yX4vaBhrqIofP018TjwDoGHnkCH6BJ
		Tfmot3kk/XVuTIs+GFbaHqDyG8PsTBIFzDYO4Tju8/85BeRgPbpa4Zxw0SCxh7La
		QtHBPMZOw0I=
		-----END PGP MESSAGE-----
	'';

	networking = {
		hostName = "lemma0";
		fqdn = "cpli.dev";
		useDHCP = false;
		wireguard.useNetworkd = true;
		firewall.allowedUDPPorts = [ 51820 ];
		firewall.trustedInterfaces = [ "fog" ];
		# the firewall as nftables, and forwarding filtered too: forwarding is
		# on for fog, and nothing else may pass through, dn42 least of all
		nftables.enable = true;
		firewall.filterForward = true;
		firewall.extraForwardRules = ''
			iifname "fog" oifname "fog" accept
		'';
	};

	boot.kernel.sysctl = {
		"net.ipv4.ip_forward" = 1;
		"net.ipv6.conf.all.forwarding" = 1;
	};

	systemd.network.enable = true;
	systemd.network = {
		networks."10-wan" = {
			matchConfig.Name = "enp1s0";
			networkConfig.DHCP = "ipv4";
			address = [ "2a01:4f8:c2c:e253::1/64" ];
			routes = [
				{ Gateway = "fe80::1"; }
			];
		};

		networks."50-fog" = {
			name = "fog";
			address = [ "10.0.1.1/32" "fc00:0010::10/128" ];
		};

		netdevs."50-fog" = {
			netdevConfig.Name = "fog";
			netdevConfig.Kind = "wireguard";
			wireguardConfig = {
				ListenPort = 51820;
				PrivateKeyFile = config.crypt.secrets.wg.path;
				RouteTable = "main";
				FirewallMark = 42;
			};
			wireguardPeers = [
				{
					PublicKey = "thm//UZxZvyjFnfWyrsyZlCHrwaCWqIrICQIC2ccOGA=";
					AllowedIPs = [ "10.0.0.1/32" "fc00:0010::1/128" ];
				}
				{
					PublicKey = "pst//8S0K2H+NA8f90KwmxoOpWAybCF85YeO4RXkVgg=";
					AllowedIPs = [ "10.0.0.4/32" "fc00:0010::4/128" ];
				}
				{
					PublicKey = "yui+/qBVDY6PCXNyFCuRJ/Gio60PzvxRYs+9AEeIUgk=";
					AllowedIPs = [ "10.0.0.10/32" "fc00:0010::10/128" ];
				}
			];
		};
	};
}
