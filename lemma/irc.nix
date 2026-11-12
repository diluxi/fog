{ config, lib, pkgs, ... }: let
	irc = "irc.amartia.online";

	# soju asks here whether a login's password is right (`auth http`): caddy
	# hands it to authelia as basic auth for irc's rule, which checks lldap
	check = "127.0.0.1:8099";

	# caddy obtains irc's certificate; soju gets a copy, its own to read
	certDir = "${config.services.caddy.dataDir}/.local/share/caddy/"
		+ "certificates/acme-v02.api.letsencrypt.org-directory/${irc}";
	run = "/run/soju";

	# as root, since caddy's directory is its own. on a fresh system caddy has
	# yet to obtain it, so this waits rather than fail soju
	copyCert = pkgs.writeShellScript "soju-cert" ''
		set -eu
		src=${certDir}/${irc}
		if [ ! -e "$src.key" ]; then
			echo "waiting for caddy's certificate for ${irc}"
			until [ -e "$src.key" ]; do sleep 2; done
		fi
		install -m 600 -o "$(stat -c %u ${run})" "$src.crt" "$src.key" ${run}/
	'';
in {
	services.soju = {
		enable = true;
		hostName = irc;
		listen = [ "ircs://:6697" ];
		tlsCertificate = "${run}/${irc}.crt";
		tlsCertificateKey = "${run}/${irc}.key";
		# history in soju's sqlite, on lemma0's own disk, so it expires: a year
		# of it, and what's deleted is reused rather than given back
		messageStoreDriver = "db";
		extraConfig = ''
			auth http http://${check}/
			# people are lldap's, so a first login makes them soju's
			enable-user-on-auth true
			message-expiry 365d
		'';
	};

	systemd.services.soju = {
		after = [ "caddy.service" ];
		serviceConfig = {
			ExecStartPre = [ "+${copyCert}" ];
			# caddy's first certificate takes a moment
			TimeoutStartSec = "3min";
		};
	};

	# soju reads its certificate again when reloaded, so a renewal doesn't
	# drop anyone's connections
	systemd.paths.soju-certificate = {
		wantedBy = [ "multi-user.target" ];
		pathConfig.PathChanged = "${certDir}/${irc}.crt";
	};
	systemd.services.soju-certificate = {
		serviceConfig.Type = "oneshot";
		script = ''
			systemctl is-active -q soju.service || exit 0
			${copyCert}
			systemctl reload soju.service
		'';
	};

	# who may: members of `irc`. authelia's basic auth is one factor, as
	# xmpp's ldap is: irc clients have nowhere to ask for a second
	services.authelia.instances.main.settings = {
		server.endpoints.authz.basic = {
			implementation = "ForwardAuth";
			authn_strategies = [ { name = "HeaderAuthorization"; schemes = [ "Basic" ]; } ];
		};
		access_control.rules = [{
			domain = irc;
			subject = [ "group:irc" ];
			policy = "one_factor";
		}];
	};
	invite.groups.irc = {
		label = "IRC (soju)";
		info = "a bouncer at ${irc}, port 6697 with tls, logged in with this username "
			+ "and password; goguma on Android, senpai on a computer";
	};

	services.caddy.virtualHosts = {
		# soju only takes 403 as a wrong password, and authelia says 401
		"http://${check}".extraConfig = ''
			bind 127.0.0.1
			forward_auth 127.0.0.1:9091 {
				uri /api/authz/basic
				header_up X-Forwarded-Proto https
				header_up X-Forwarded-Host ${irc}
				header_up X-Forwarded-Uri /
				@refused status 401
				handle_response @refused {
					respond 403
				}
			}
			respond 200
		'';
		${irc}.extraConfig = ''
			# pin the issuer, so the certificate stays where soju looks for it
			tls {
				issuer acme {
					dir https://acme-v02.api.letsencrypt.org/directory
				}
			}
			respond 404
		'';
	};

	networking.firewall.allowedTCPPorts = [ 6697 ];
}
