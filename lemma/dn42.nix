{ config, ... }: {
	crypt.secrets."dn42-390".user = "systemd-network";
	crypt.secrets."dn42-390".text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0A4OIP51NGb9yjRaNPopYTgawoO
		qbOyDj/UxOpDynh0QzBU2B/pgq+xq8pxViMa406yO8tn33zE2mO4LYynf5NUY0OS
		e7Pw7c0jrIhDm8rC4xzBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQOBlO4Pa
		yy5geIWtepKTf9xKhTL7fUcmiEYWTGOGcag1MHWweSxmDbZ5zEOvoLiU2XaUkBFN
		e0Oqd5nPO78WAvuK7ig65/LM7LZWupZpFzb3QtJ6AgkCBqGr4d5U1IsEJQHeOo3w
		nl5egAmZFjG0eaxnbCUMwmzrGy7ohLr6bBvWkcMHwFHIyVh74ZwUysLaJZyZ+rmY
		lB9Q1oHRu01PF4Hl+jU6XUnU9haGX9aLYzDGd5z4ADVHx+8XB/joxzaNvLa8Myl1
		aYTrj5dciyw=
		-----END PGP MESSAGE-----
	'';

	crypt.secrets."dn42-390-psk".user = "systemd-network";
	crypt.secrets."dn42-390-psk".text = ''
		-----BEGIN PGP MESSAGE-----

		wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0CU98HDXb1adIWbhcsiyYtWdJdG
		PqTWCdEjMuZJpPx/AzCkoyEkd5OB5a9DZY8gxV2x3Y3pqCHyGWDXZCXnU6V6/faS
		GC8hZ6rWVFrBKTQHz93BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQHQLKZcq
		kX1hkYGWBoCFrqGi/tY21XZNxKnRG5UgXLx+MEFnxR5Ty+GIhGWQSk1iS77P/kN3
		umRkwwgXn/lmYK/cZkXfEWmCX5Larl7/HIE4tNJ6AgkCBjoSkl/zzuLBBsVsLAKJ
		dmCzXeDgAVkBBSMEh6mdNwFqKa9TBTKglGUEBruneaPkDQGoQEcQYnXta0PWez/U
		lddtUhtzpOJzfSIYxUP2NnKzx1o0TD2SYGVOUT3pCTzE8Yv8uaGL+2WpITx1SMn0
		zVaaXoxCTNc=
		-----END PGP MESSAGE-----
	'';

	networking = {
		firewall.allowedUDPPorts = [ 4201 ];
	};

	systemd.network = {
		networks."50-dn42" = {
			name = "dn42";
			address = [ "fe80::acab/64" ];
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
					Endpoint = "[2a01:e0a:fc5:8323::42]:42006";
					PresharedKeyFile = config.crypt.secrets."dn42-390-psk".path;
					PublicKey = "faHyobVhLCte+Bt6QtRV+5QSlWlzA0bTzLo3jXxYcDU=";
					AllowedIPs = [ "fe80::390/64" ];
				}
			];
		};
	};
}
