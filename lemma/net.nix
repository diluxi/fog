{ config, ... }: {
	crypt.secrets.wg.user = "systemd-network";
	crypt.secrets.wg.text = ''
		-----BEGIN PGP MESSAGE-----

		wcFMA3eZGxD4Ook8ARAAw5vHU8znvGykIJZtc0BmaQ5csFHD5ixgSRd8WYBdhl+R
		0jSzyhzVIeU+vRNEpruQ7svIynrXc2wFHahkgbq2q+IjDWGbBtZjQfywRMic/26Q
		EjjzgkSXydmlOh67hCjjbDk3HOIwgbuUqvJhvkIODcukruWwcLVkRkbqHBeeVnbL
		jxEARWE01I6HKQwsHmec00hdN5j/zuTYDK5zN/cCX8XMfBhRgKNeOiBobAO1hwzd
		BM6VMURCtxIHpleFwVcdA+0HgYgdftyuWO7+JrNpSkJd3iYcVN0VyS8YyqiZraFv
		zC4iCNDhIGW8jcbZyHh+boT3yBQ40YzNVR+b22m/f69RLQO6i1cmzlN5fwsycEf3
		MtKHR0fXBHmTLK2lt7aMYpyo7660Ub89UCnxhbvHVirlUVc0TQyE3nPmI9gsgF1W
		zwcqHtKGw+oxWHevI970mNRyiT3/f/TMon6DIy5TMDB9iRJ9hRzPedj0Yfv6t2Wn
		ITWUhLoYkUvTYyUOLfyQ0T5FXKH+WQ6RVAzTdJW8dHAyDXNOsE5yafDSklqvIy3t
		P0ira0NpFjg2SXR9YBjnMGjuPGNw9KlT7nhN/YxiBAlJJt01EdIf3pF6VZW6U4nw
		e6WTLukLpQddcMQQUwUzloQxehl7LWiHJ8YjD6RTkl4aRshbitB1nPtKASkZ7oDB
		XgPhmLVO0u7S+xIBB0DEGujnbt61TYXUpNuYpXrHGwK9hp4elMbx4Z3jOtneTjDW
		HwoHf+CEivyWZhiN+cWevONhqI2lqUXisCoCrWSJltnQzYa68FuRDaccxSj7FvfS
		XQGix0y8MZtaJquLD4Cy36DP+EiZOvBzI/y3Ieh1SPzxWqMcEvA47nAILYJw1vkT
		ue3RpMOQr3QZfR0re+JW6HzXKcuGDu2JE5xqzj2dLnMwDMjgq5+O0PfTL11GOw==
		=VoXC
		-----END PGP MESSAGE-----
	'';

	networking = {
		hostName = "lemma0";
		fqdn = "cpli.dev";
		useDHCP = false;
		wireguard.useNetworkd = true;
		firewall.allowedTCPPorts = [ 51820 ];
		firewall.allowedUDPPorts = [ 51820 ];
	};

	boot.kernel.sysctl = {
		"net.ipv4.ip_forward" = 1;
		"net.ipv6.conf.all.forwarding" = 1;
	};

	networking.firewall = {
		extraInputRules = ''
			iifname "fog" accept
		'';
		extraForwardRules = ''
			iifname "fog" oifname "fog" accept
		'';
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
			];
		};
	};
}
