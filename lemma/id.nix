{ config, ... }: let
	domain = "amartia.online";
	baseDN = "dc=amartia,dc=online";
	auth = "auth.${domain}";
	ldap = "ldap.${domain}";

	# secrets reach both services through LoadCredential, so they stay
	# root-owned in /run/crypt; lldap's DynamicUser doesn't exist at activation
	secret = name: config.crypt.secrets.${name}.path;

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';
in {
	crypt.secrets = {
		# lldap's root, the break-glass account
		lldap-root.services = [ "lldap" ];
		lldap-root.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0BQnuh67sNi1pbivu2v4yA8/aGO
			70mWTeGaBBIYlszhDjCmRNV1pl4LBHvn/aWjvwjpoJkVDyaiJHWqUaTgSwR8EqQa
			AketeVutF5EfIz2sACLBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQDKljvv6
			zChHEgRMQOE+clUyQs6/Z7uyuY9kSm9l2oNjMBr+vluml7+mWCp/3VkwABkVZ39G
			wAw/cvgFuDtGmwinyFNCaidAnxs/7KePAv/u+NJ+AgkCBmDXp4l/eUUH9c5ahmSh
			hYrjpaBl5icUrVB0SqWVHj4B2dq/nt636Y92mf8ijKeNQcbMDdsp1mKyci+1h5Yw
			w9/aCW+AehxyKfm8J11sXr+62Dz2xTS3ecBncDFhgxJ0BXBjEg9Bc0ae9NRXcIMe
			A2c0vMvyd2ySRmbP
			-----END PGP MESSAGE-----
		'';
		lldap-jwt.services = [ "lldap" ];
		lldap-jwt.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0AGV7r1SR2G8jFkKxYPEzoEAkAL
			dJaazcpqov9WD11XbDAa1qMaTl1gOzW4rv8prmoZ4xhbb2AwfkRiUMNiYjBNubMt
			PiZDHwiwxY4cNWVnILXBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQA+loKlY
			zZAscP+Ncpq6h3AmLbHbMJnBR/9Tu2J6tVxIMDipwbLVNQMtnKAtzpk/8Lo5sNPE
			GVKJH5ROsbm4dkpEVCxm5Nx+iezDE7oQQWUmz9KWAgkCBiU2N4pyFhO34pEJ8UTS
			gQFIyQCPQylTp1J4kfX2Nysf1iGHeVxiX/33xDQTJ3+gYXqFo8GoPk630Iq0kiKr
			xqGPlFv1uAoE0RQqP2KSyfU9E6B9sdqMdbpvHlBFAkarHKw9kh3wI18Zb23py410
			CPVQelcOt7Z1/BmSRe+xsSpb0c6QTo7HMtAiI0yOvLDY8Xdn
			-----END PGP MESSAGE-----
		'';
		# key_seed derives lldap's password-hashing key. losing it voids every
		# stored password, so it lives here rather than only in /var/lib
		lldap-env.services = [ "lldap" ];
		lldap-env.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0Dje55fOZf9Hq1eEf5UtNJZuQBb
			nGMbpB+8fi6c5P9xEDDfMt4/vu0jO1NQgl6mT06I+uWf8YjZdSSaIER8XXzylOLx
			OVBm9oQ8UpZYOVl+tb/BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQOX2vGy4
			M5rNirgcIcTve3NrRotN72Rndr9F5SYrsgwOMNXH6Igqv/mHR2yl9vK4meiU8pg+
			2CMUjDpsoVzE4heVYD+cAjgSPlRmx5cIVlJr4tKeAgkCBmNYHj5jJjCnGKoGvEkE
			b9c7xWMaSieU8mwaTlQ7VipgRuQDo5uy9lyIaH+bAe67REpokViq9AN6TS2tcSQx
			LwVf3pT6maEp1dIBXeg27QDq7mQrQbXFz7p8elxVFYc8qdjbm4VHzMAp8/MdkPKq
			ESugMkholL8X6yGELvSKwH3oh3UZbLy8qKKVrzqvKHD9rrttdNIkBK97UCE=
			-----END PGP MESSAGE-----
		'';
		authelia-jwt.services = [ "authelia-main" ];
		authelia-jwt.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0AcBaJ+nZUz7J3HY5NO5d6IcrwO
			4shSWCV8DLVvU8BFMzAQqFK9TCkP4Q5BfCcd7sS1S+Lmucgs8k7eoatY+lv5ib5o
			AJS5aq9fWVSkmxiIx/zBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQCBSrEMA
			wWTjl0WL5aQHe69IiHwOO8NVD/MGUW2pGQsEMJHuRkUZc48e6IAT3Ic+F490c9y5
			z30SxPjLWc0FgLmXCIIxKbXFMB9oig6nvANM79KWAgkCBq29JeZ9wbzaq1oV6XCn
			YDbCEJsQJArdiTPusjR91BBY4X9Z63K59M7e6O9mC+KeIjTtepbDyardneagWCt4
			DokLIrtq/7HlBlmALyaI8xnqqERyIyScODvk59D/mzzxSg8ft7uBmT4+dS4pA7W7
			QK2ZIa7y3RN65ur/HsvES5SGgtJl3JMI6W8440SM5PdSPa3S
			-----END PGP MESSAGE-----
		'';
		authelia-session.services = [ "authelia-main" ];
		authelia-session.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0Bw51T9HMaOWqPAzFOaSIoQjsed
			Upz0CEGsCcAgjTYOKjC6xajKHnrQPsrgu06GsVWtj0/Ubbv2m0Brb0Pxj93NlUne
			W+SFGh80bbkMX9+Lpn/BbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQEhBs7fB
			4Ht6+c4lfHNtu78jWivJ7waNXvEifm5hWhZGMDn7Xk9dhgl9TqLcLPXY4Tu3Lmq/
			4y3MjAYUa6FAU/FMvc0igdoGHImf3jws9pHxS9KWAgkCBs+namuvkTE46oBc2zMb
			sxsN+2BlgRd3RiqMVz6aCPAC4rk1GYLJ1nFc66WlpBwvZytqy3KWBhfvf/ZSPM5f
			nsiWzws7CTIgiLppMdHtEcfuDJQ1nIlUv0euaUD6oaCCIBr9xo7C8iG6ov1NLgDp
			VTnZFhYpzM3+0zME70W5fnO4THaTdFIBnvYVs/jV3ikXRHBs
			-----END PGP MESSAGE-----
		'';
		# password of lldap's `authelia` account (in lldap_password_manager)
		authelia-ldap.services = [ "authelia-main" ];
		authelia-ldap.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0D0F/EB0KzazxtDn2e8vP++pwE6
			wCLUka1c2XyVzW5AEDDf0KTapS6ETyHboZ1qKa400/L6ftpqTjD7bWDF1cj5FVLg
			wQfVIjtmXXUohuECo+bBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQI1o6pLZ
			c+WPqnUxZNpjLk2G4AKMJo6+SJOF0Ae/ZeoqMIvzaf3ecZputMfXqFd4v8dJW425
			eVTlKaTfggCEdXDNPhF7L0y0Mcihs3t57JVQiNJ6AgkCBp0Sr5vxcgG4EpXsC+Vu
			dWot9gQsxZLT4f5mbkrh5TdUrt5LBGTmFoQuCLQQqHWJMB7x51C/BHjpGLNa+Exb
			zPmiYTYjHphRPrxdf3i9AQ+y0CwLuQVp+t3bDOzFTTXDFsXge86Y4ZRIFELyX7WR
			LO3VfXmeXDA=
			-----END PGP MESSAGE-----
		'';
		authelia-storage.services = [ "authelia-main" ];
		authelia-storage.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0CAeDU1erv2TtfiYX27rbg8kNoB
			8xmSg3q5Rp3owa6cdjAg7qNjVCkGgzir6kL9zhSBy5DUt9stAw+tIdy+YlMnbuPj
			0H7U/BReHiv6ttMLyjDBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQHcSIwHR
			eWQBvKEiAqe2+NjSpTEAsJa07EnKJdrWKlQVMPUXM24QhOZrYr5ZucsY+Fr1uDBE
			IcwF+VNUH0DJhKrU7FYPoCsAI+OjllBG9zOWu9KWAgkCBqhPP4qbU6WMM4/qOFk/
			RM1fGsY4W5mKiACp2L6Xt9f3Xqo49iRfgIdWF7q9MWH1FeaUwQyFZd7AmIBxePi3
			ZdOThyyFJLX6oZJ0yH2EsE4iThbipHD0JCLjXMX6gI65jQZLAWwbqFEsKnXbiDn5
			ZBFuaIOEdUYq/gk6cz35ls2tWIL2PBzG0QYPF7sEkm0rtyA1
			-----END PGP MESSAGE-----
		'';
	};

	services.lldap = {
		enable = true;
		settings = {
			ldap_host = "127.0.0.1";
			http_host = "127.0.0.1";
			http_url = "https://${ldap}";
			ldap_base_dn = baseDN;
			# root: the declarative break-glass account, which services bind as.
			# people administer lldap as members of lldap_admin instead
			ldap_user_dn = "root";
			ldap_user_email = "root@${domain}";
			key_file = ""; # the key comes from LLDAP_KEY_SEED in lldap-env
			# root's password is declarative; changing it in the ui won't stick
			force_ldap_user_pass_reset = "always";
		};
		environment = {
			LLDAP_JWT_SECRET_FILE = "%d/jwt";
			LLDAP_LDAP_USER_PASS_FILE = "%d/root";
		};
		environmentFile = secret "lldap-env";
	};
	systemd.services.lldap.serviceConfig.LoadCredential = [
		"jwt:${secret "lldap-jwt"}"
		"root:${secret "lldap-root"}"
	];

	services.authelia.instances.main = {
		enable = true;
		secrets = {
			jwtSecretFile = secret "authelia-jwt";
			sessionSecretFile = secret "authelia-session";
			storageEncryptionKeyFile = secret "authelia-storage";
		};
		environmentVariables.AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE =
			"%d/ldap-password";
		settings = {
			theme = "auto";
			server.address = "tcp://127.0.0.1:9091/";
			log = { level = "info"; format = "text"; };

			authentication_backend.ldap = {
				implementation = "lldap";
				address = "ldap://127.0.0.1:3890";
				base_dn = baseDN;
				# its own account: lldap_password_manager may read everyone and
				# reset passwords of all but lldap_admin, which is what authelia's
				# password reset needs and no more
				user = "uid=authelia,ou=people,${baseDN}";
			};

			# nothing is reachable unless a rule says so
			access_control = {
				default_policy = "deny";
				rules = [{
					domain = ldap;
					subject = [ "group:lldap_admin" ];
					policy = "two_factor";
				}];
			};

			session.cookies = [{
				inherit domain;
				authelia_url = "https://${auth}";
			}];
			storage.local.path = "/var/lib/authelia-main/db.sqlite3";
			# no mail until stalwart: read with run0 cat
			notifier.filesystem.filename = "/var/lib/authelia-main/notifications.txt";
			totp.issuer = domain;
		};
	};
	systemd.services.authelia-main = {
		wants = [ "lldap.service" ];
		after = [ "lldap.service" ];
		serviceConfig.LoadCredential = [ "ldap-password:${secret "authelia-ldap"}" ];
	};

	services.caddy.virtualHosts = {
		${auth}.extraConfig = ''
			reverse_proxy 127.0.0.1:9091
		'';
		# lldap's own ui, for lldap_admin with a second factor
		${ldap}.extraConfig = ''
			forward_auth 127.0.0.1:9091 {
				uri /api/authz/forward-auth
				copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
			}
			reverse_proxy 127.0.0.1:17170
		'';
	};
}
