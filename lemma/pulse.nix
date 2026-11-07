{ config, lib, pkgs, ... }: let
	pulse = "pulse.amartia.online";
	auth = "auth.amartia.online";
	port = 3000;

	# placeholder until the encrypted secret is pasted in its place
	todo = name: how: throw ''
		crypt.secrets.${name} is missing. generate it with
			${how}
		encrypt it to lemma0 and lux, and paste the armored message here.
	'';

	# the dashboard, as nix. a panel is a title, a kind, a unit and its
	# queries; `row` lays a list of them out side by side, 24 columns wide
	query = expr: legend: { inherit expr; legendFormat = legend; };
	panel = kind: title: unit: targets: {
		inherit title targets;
		type = kind;
		datasource = { type = "prometheus"; uid = "prometheus"; };
		fieldConfig.defaults = { inherit unit; };
		options = lib.optionalAttrs (kind == "timeseries") {
			legend = { displayMode = "list"; placement = "bottom"; };
		};
	};
	stat = panel "stat";
	gauge = title: targets: panel "gauge" title "percentunit" targets // {
		fieldConfig.defaults = {
			unit = "percentunit";
			min = 0;
			max = 1;
			thresholds = {
				mode = "absolute";
				steps = [
					{ color = "green"; value = null; }
					{ color = "orange"; value = 0.75; }
					{ color = "red"; value = 0.9; }
				];
			};
		};
	};
	graph = panel "timeseries";
	# daily or hourly totals as bars rather than lines
	bars = title: unit: targets: graph title unit targets // {
		fieldConfig.defaults = {
			inherit unit;
			custom = { drawStyle = "bars"; fillOpacity = 60; stacking.mode = "normal"; };
		};
	};
	row = y: h: panels: lib.imap0 (i: p: p // {
		gridPos = {
			inherit y h;
			w = 24 / lib.length panels;
			x = i * (24 / lib.length panels);
		};
	}) panels;

	wan = ''device="enp1s0"'';
	root = ''mountpoint="/"'';
	# stalwart names its counters after its events (message-ingest.ham is
	# message_ingest_ham); they restart at zero with stalwart, which
	# increase() accounts for
	mail = name: legend: query "sum(increase(${name}[1h]))" legend;

	dashboard = {
		uid = "lemma0";
		title = "lemma0";
		timezone = "browser";
		refresh = "1m";
		time = { from = "now-7d"; to = "now"; };
		schemaVersion = 39;
		panels = lib.concatLists [
			(row 0 4 [
				(stat "up" "s" [ (query "time() - node_boot_time_seconds" "") ])
				(gauge "disk /" [ (query
					"1 - node_filesystem_avail_bytes{${root}} / node_filesystem_size_bytes{${root}}" "") ])
				(gauge "memory" [ (query
					"1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes" "") ])
				(stat "load (5m)" "short" [ (query "node_load5" "") ])
				(stat "failed units" "short" [ (query
					''sum(node_systemd_unit_state{state="failed"})'' "") ])
				(stat "mail queue" "short" [ (query "queue_count" "") ])
			])
			(row 4 8 [
				(graph "traffic" "bps" [
					(query "rate(node_network_receive_bytes_total{${wan}}[5m]) * 8" "in")
					(query "-rate(node_network_transmit_bytes_total{${wan}}[5m]) * 8" "out")
				])
				(bars "traffic per day" "decbytes" [
					(query "increase(node_network_receive_bytes_total{${wan}}[1d])" "in")
					(query "increase(node_network_transmit_bytes_total{${wan}}[1d])" "out")
				] // { interval = "1d"; })
			])
			(row 12 8 [
				(graph "disk used" "decbytes" [ (query ''
					node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|vfat"}
					- node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|vfat"}
				'' "{{mountpoint}}") ])
				(graph "cpu" "percentunit" [ (query
					''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))'' "busy") ])
				(graph "memory" "decbytes" [
					(query "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes" "used")
					(query "node_memory_MemTotal_bytes" "total")
				])
			])
			(row 20 8 [
				(bars "mail per hour" "short" [
					(mail "message_ingest_ham" "received")
					(mail "message_ingest_spam" "spam")
					(mail "queue_queue_message_authenticated" "sent by us")
					(mail "delivery_delivered" "delivered out")
				] // { interval = "1h"; })
				(bars "mail trouble per hour" "short" [
					(mail "auth_failed" "failed logins")
					(mail "smtp_mailbox_does_not_exist" "unknown recipient")
					(mail "delivery_dsn_perm_fail" "bounced")
					(mail "smtp_dmarc_fail" "dmarc fail")
				] // { interval = "1h"; })
			])
			(row 28 8 [
				(graph "web requests by site" "reqps" [ (query
					"sum by (host) (rate(caddy_http_requests_total[5m]))" "{{host}}") ])
				(graph "web responses by status" "reqps" [ (query ''
					sum by (code) (rate(caddy_http_request_duration_seconds_count[5m]))
				'' "{{code}}") ])
			])
		];
	};
	dashboards = pkgs.writeTextDir "lemma0.json" (builtins.toJSON dashboard);

	# authelia checks grafana's client secret against this hash, so only
	# grafana holds the secret. `authelia crypto hash generate pbkdf2
	# --variant sha512 --random --random.length 64 --random.charset
	# alphanumeric` prints both: the password goes into grafana-oidc
	# (without a newline), the digest here
	grafanaDigest = throw ''
		pulse.nix: grafana's client secret digest is missing. generate it with
			authelia crypto hash generate pbkdf2 --variant sha512 --random \
				--random.length 64 --random.charset alphanumeric
		and paste the digest in place of this throw.
	'';
in {
	crypt.secrets = {
		# grafana's client secret at authelia; see grafanaDigest
		grafana-oidc.services = [ "grafana" ];
		grafana-oidc.text = ''
			$pbkdf2-sha512$310000$mwE2inMz.d9JiQWQf//hrw$qH00BORfDvQd1kRjWd32KF4LeSpUqrAerXuNEpBtBHDViEUUxq5ZotqSiEEVnfocE4HliPqCPG2DX4n4q6n7ww
		'';
		# signs grafana's cookies and encrypts its stored secrets
		grafana-secret-key.services = [ "grafana" ];
		grafana-secret-key.text = ''
			-----BEGIN PGP MESSAGE-----

			wWwGFQQHYeuJ8PnxS6NfpKfm2+WoI81L/BIBB0DrX5LcQzy7ZvY1BSfulffxwQZu
			Pii89rWJyF2oMhuKRDC0Cm3OkQJROLjuptE1J4yx1A6s3MD86RjTT6X9pS0CiAvT
			3PLXJ3X/orVryI9Db8jBbAYVBIxeW63uQw6sWG5vC987KBsinEoSEgEHQDDFhHZp
			ld4HTIvr5p8EiKg9rmjSHAQGrxgHnCxf3PwXMEcP5VBM3eB+Y7EvxmxkmzefJfoe
			Lwo8NSx+KTWTU3aZUnukAOjazWbgrKia8JLNl9KOAgkCBsYF2YwUQxqvgE1hJYM2
			i2inhESYVokZDaE21RR48vkRtqchIlKpsmixDIA8R9ynoU4sxcWuHknqNQXahcA+
			i2i5XUuOqsj6yQNqnkrtYHMbnA05l2h7szfOpI6/sc5rp8gnRYJFv49tPeoVTXat
			my/mAtQARUOvb+eoIca58f0wMjCiFQxI9OXhjw==
			-----END PGP MESSAGE-----
		'';
	};

	services.prometheus = {
		enable = true;
		listenAddress = "127.0.0.1";
		retentionTime = "1y";
		globalConfig.scrape_interval = "30s";
		exporters.node = {
			enable = true;
			listenAddress = "127.0.0.1";
			enabledCollectors = [ "systemd" ];
		};
		scrapeConfigs = [
			{
				job_name = "node";
				static_configs = [{ targets = [
					"127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
				]; }];
			}
			{
				# caddy's admin api; it only answers to localhost
				job_name = "caddy";
				static_configs = [{ targets = [ "localhost:2019" ]; }];
			}
			{
				job_name = "stalwart";
				metrics_path = "/metrics/prometheus";
				static_configs = [{ targets = [ "127.0.0.1:8080" ]; }];
			}
		];
	};

	# requests per site; caddy's metrics need switching on
	services.caddy.globalConfig = ''
		metrics {
			per_host
		}
	'';

	services.grafana = {
		enable = true;
		settings = {
			server = {
				http_addr = "127.0.0.1";
				http_port = port;
				domain = pulse;
				root_url = "https://${pulse}/";
			};
			security.secret_key = "$__file{/run/credentials/grafana.service/secret-key}";
			analytics = { reporting_enabled = false; check_for_updates = false; };

			# logins only through authelia, and only for lldap_admin, who
			# administer grafana too
			auth.disable_login_form = true;
			"auth.generic_oauth" = {
				enabled = true;
				name = "Authelia";
				auto_login = true;
				client_id = "grafana";
				client_secret = "$__file{/run/credentials/grafana.service/oidc}";
				scopes = "openid profile email groups";
				auth_url = "https://${auth}/api/oidc/authorization";
				token_url = "https://${auth}/api/oidc/token";
				api_url = "https://${auth}/api/oidc/userinfo";
				use_pkce = true;
				login_attribute_path = "preferred_username";
				name_attribute_path = "name";
				groups_attribute_path = "groups";
				role_attribute_path = "contains(groups[*], 'lldap_admin') && 'Admin'";
				role_attribute_strict = true;
			};
		};
		provision = {
			enable = true;
			datasources.settings.datasources = [{
				name = "Prometheus";
				type = "prometheus";
				uid = "prometheus";
				url = "http://127.0.0.1:${toString config.services.prometheus.port}";
				isDefault = true;
			}];
			dashboards.settings.providers = [{
				name = "fog";
				options.path = dashboards;
			}];
		};
	};
	systemd.services.grafana.serviceConfig.LoadCredential = [
		"oidc:${config.crypt.secrets.grafana-oidc.path}"
		"secret-key:${config.crypt.secrets.grafana-secret-key.path}"
	];

	services.authelia.instances.main.settings.identity_providers.oidc = {
		authorization_policies.pulse = {
			default_policy = "deny";
			rules = [{ policy = "two_factor"; subject = "group:lldap_admin"; }];
		};
		clients = [{
			client_id = "grafana";
			client_name = "pulse";
			client_secret = grafanaDigest;
			authorization_policy = "pulse";
			require_pkce = true;
			pkce_challenge_method = "S256";
			redirect_uris = [ "https://${pulse}/login/generic_oauth" ];
			scopes = [ "openid" "profile" "email" "groups" ];
			token_endpoint_auth_method = "client_secret_basic";
		}];
	};
	services.caddy.virtualHosts.${pulse}.extraConfig = ''
		reverse_proxy 127.0.0.1:${toString port}
	'';
}
