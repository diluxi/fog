{
	networking.firewall.allowedTCPPorts = [ 80 443 ];
	# hosts with their own module add vhosts; websites are lemma/ecdo.nix's
	services.caddy.enable = true;
}
