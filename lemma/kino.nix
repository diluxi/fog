{ config, ... }: {
	services.jellyfin = {
		enable = true;
		openFirewall = true;
	};

	services.caddy = {
		virtualHosts."kino.${config.networking.fqdn}".extraConfig = ''
			reverse_proxy 127.0.0.1:8096
		'';
	};
}
