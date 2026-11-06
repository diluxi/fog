{
	config,
	...
}: {
	networking.firewall.allowedTCPPorts = [ 80 443 ];
	
	services.caddy = let
		fqdn = config.networking.fqdn;
	in {
		enable = true;
		virtualHosts."audit.${fqdn}".extraConfig = ''
			root * /srv/http/audit
			file_server
		'';
		virtualHosts.${fqdn}.extraConfig = ''
			root * /srv/http/${fqdn}
			file_server
		'';
		virtualHosts."amartia.online".extraConfig = ''
			root * /srv/http/amartia.online
			file_server
		'';
	};
}
