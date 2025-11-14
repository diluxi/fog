{ config, ... }: {
	crypt.secrets."dn42-390".user = "systemd-network";
	crypt.secrets."dn42-390".text = ''
		-----BEGIN PGP MESSAGE-----

		wcFMA3eZGxD4Ook8AQ//eDCcYc8S59FERbKLiKeAA3B47YkqtRPlNxLBvBVWq0Ac
		Y3w0seeTBpIS56gBeQNmwhfGJfDa9cK+826sJ/6yCigPHYjImhrQ9wkGqCE3IimL
		GV3JYM49E07n4rgHTI/gAw7ERFr49qnvhku+TT78NqATuxJQdJME5JYWttazcrdk
		rfIT7zeO5gzVNBRjnQXHPwIEvzWzDDSL2xAj1xPzRBc+A94J24mpkX9xW8ze2eDD
		SevauJz4mq9ZJRlhFuO0ddHIOIJkwk/h3yPVBR60qkpL5Qns4yvM7fO9stVEVinC
		/Jz22nPdrXDObBB7kO5EtmizZfUfMT1k5FtgGaOa+7LrjyU/aSzsEYNs2zJ0iLCG
		VhDJuyKsSQF6Svfz4/kiCEmXiSspkoaRVUBgvPol02gUg6/wNOl7QxWb35c1c2/J
		iB40R7JRohFe1HCrYrd5nEkaSjzxqr51e9d4mRYMZDMYRXkLp7BE2cugsNg1lhiL
		6KaRRny49xH5XOmBAAQ5GiZbETd/Q4AddAbfiD1rB/fawKTxJf3c25uDbQLfHv6J
		60D4eWzQvWj6y/rs26Z970gH5asFQqgDixPnusIS1q83eY20/4s3cxlmkQwl7xAd
		txHIlKaGgFlyIcgvLW9Tz/CL8rJWduaelyVJeMpcOna4OHw4roudutM32Y7QFTHB
		XgPhmLVO0u7S+xIBB0CaEmEx6DZkHM58DLG/K+39NVKyvGSDScsQ52/L/P3eFzB+
		3TplRm7k8qBRLTzEjnQiyLeuyDAxJqc5XA9fDnuu3P2ysMTY5rksdDTmzW140jHS
		XQF3d/rN+DuXZJoU2UkfpQbWmobtzjYi46Xe762soZjYobRCPjXWXoxQVQIq/NlJ
		Q+D9s6NKPrmSw6tNF+PMP6R46J7egdO0KY3LnHcRRw2dmLKWeZrHq00f6BZlYQ==
		=GZhd
		-----END PGP MESSAGE-----
	'';

	crypt.secrets."dn42-390-psk".user = "systemd-network";
	crypt.secrets."dn42-390-psk".text = ''
		-----BEGIN PGP MESSAGE-----

		wcFMA3eZGxD4Ook8AQ/+LauPjJ/9dD0bcc6wZAWcY77VSIrucuzOZsN+gkws65Ps
		m88YRby/mE4Wl+FzRaj4uTgx2GOwnb4JzQonu3kD5XWdnE87VWFa2j7fCc/4tuLn
		VryEOix5NU98vWhTowFXDUvetKGi2VeXD5vJIg9TkfAWIOqhp8uLGfzj14RjFzyw
		vomjo+JjVvZ9Zq01ey6hZcCiEcu4+J7spX6eRZdJkKfcBcBqVnfxNiNpjRvcIxgM
		oWD12h5osJ7mTBx44cUMbQYWFt0GUT3gVaC18OwLtZ19hisMt8o1Xos0UyL2kQch
		okrkSo79ZLIotDLttRDJ4U938Ma3E1uVMjW1/iFzNClmB2LDEZTm2fQXjK3CeOcs
		pddLQLJPGviO2t2Sks5s4W62pWXbn8wPlHonIY1o/TVhKO3SI2Cz6oK6IBLkdYOX
		DoonOrW4rW1Wzi3vrSYpf4svV+fEFwyfGqvMckSDxsQrmznIzuDXTIMsoKV7AQbJ
		+WymukEZtDIvGCIxOM+UAHNTVH1+b1tl/Vk8Zkk5f3d5DvfYQPqL79ChsypuOJE2
		cjUdhmsIKQKrv7x8kXgn6sSV10p5i9nNhnfxc5ltPuPllvnZvr/4uNoZMvvoC6/C
		rGhkjQokSZTlYkWbCMCk9bbpu2ZfsORvII9ls1P2tM86tZm9zdvv6hqg2fglA1DB
		XgPhmLVO0u7S+xIBB0BSfxh0Uv4norS5nChLBUmxq7XM8Klmn2E/tjSq3dlpGjBu
		ehaDd5aNHxyBP/1dYu0p8+b4BnaYbFXtbQcc5U4Y+RwpkzauqjRM+vecWpXvIS3S
		XQEONR+4mHss9Tv6Q4I8KgNCPgW1Hz06HmwLQjrA0CL5q1ujApHyL6d2pel8i9m1
		2+WFLNeS9Ll/4MInsiF2+wPrMCZzYe4TuXNI4XSH/inq9FRPmK3/HY5v/NCowg==
		=doya
		-----END PGP MESSAGE-----
	'';

	networking = {
		firewall.allowedTCPPorts = [ 4201 ];
		firewall.allowedUDPPorts = [ 4201 ];
	};

	systemd.network = {
		networks."50-dn42" = {
			name = "dn42";
			address = [ "fc80::acab/64" ];
			addresses = [
				{
					Address = "fc80::390/64";
					# Peer = "fc80::390/64";
				}
			];
		};

		netdevs."50-dn42" = {
			netdevConfig.Name = "dn42";
			netdevConfig.Kind = "wireguard";
			wireguardConfig = {
				ListenPort = 4201;
				PrivateKeyFile = config.crypt.secrets."dn42-390".path;
				RouteTable = "main";
			};
			wireguardPeers = [
				{
					PresharedKeyFile = config.crypt.secrets."dn42-390-psk".path;
					PublicKey = "faHyobVhLCte+Bt6QtRV+5QSlWlzA0bTzLo3jXxYcDU=";
					# AllowedIPs = [ "0.0.0.0/0" "::/0" ];
					AllowedIPs = [ "fc80::390/64" ];
				}
			];
		};
	};
}
