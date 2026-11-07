{ config, lib, pkgs, ... }: let
	pulse = "pulse.amartia.online";
	auth = "auth.amartia.online";
	port = 3000;


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
	# stat and gauge panels show the current value, whatever the time range:
	# a range query that coarse can miss every sample of a young prometheus
	instant = p: p // { targets = map (t: t // { instant = true; range = false; }) p.targets; };
	stat = title: unit: targets: instant (panel "stat" title unit targets);
	gauge = title: targets: instant (panel "gauge" title "percentunit" targets) // {
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
		time = { from = "now-24h"; to = "now"; };
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
					(query "rate(node_network_receive_bytes_total{${wan}}[$__rate_interval]) * 8" "in")
					(query "-rate(node_network_transmit_bytes_total{${wan}}[$__rate_interval]) * 8" "out")
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
					''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))'' "busy") ])
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
					"sum by (host) (rate(caddy_http_requests_total[$__rate_interval]))" "{{host}}") ])
				(graph "web responses by status" "reqps" [ (query ''
					sum by (code) (rate(caddy_http_request_duration_seconds_count[$__rate_interval]))
				'' "{{code}}") ])
			])
		];
	};
	dashboards = pkgs.writeTextDir "lemma0.json" (builtins.toJSON dashboard);

	# grafana's client secret, made on lemma0 with its pbkdf2 digest beside
	# it: grafana reads the secret, authelia only the digest
	oidc = config.crypt.generated.grafana-oidc.path;
in {
	crypt.generated = {
		grafana-oidc.script = ''
			${pkgs.authelia}/bin/authelia crypto hash generate pbkdf2 \
				--variant sha512 --random --random.length 64 \
				--random.charset alphanumeric >$out.both
			sed -n 's/^Random Password: //p' $out.both | tr -d '\n' >$out
			sed -n 's/^Digest: //p' $out.both | tr -d '\n' >$out.digest
			rm $out.both
		'';
		# signs grafana's cookies and encrypts what it stores
		grafana-secret-key = {};
		grafana-admin = {};
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
		# grafana 13 no longer bundles the prometheus data source
		declarativePlugins = [ pkgs.grafanaPlugins.prometheus ];
		settings = {
			server = {
				http_addr = "127.0.0.1";
				http_port = port;
				domain = pulse;
				root_url = "https://${pulse}/";
			};
			security = {
				secret_key = "$__file{/run/credentials/grafana.service/secret-key}";
				# unusable with disable_login, but never the default either.
				# only applies when grafana creates its database
				admin_password = "$__file{/run/credentials/grafana.service/admin}";
			};
			analytics = { reporting_enabled = false; check_for_updates = false; };

			# logins only through authelia, and only for lldap_admin, who
			# administer grafana too. disable_login switches grafana's own
			# passwords off entirely: the login form, and basic auth on the
			# api, where the built-in admin would otherwise answer to the
			# nixos default admin:admin
			auth = {
				disable_login = true;
				disable_login_form = true;
			};
			"auth.basic".enabled = false;
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
		"oidc:${oidc}"
		"secret-key:${config.crypt.generated.grafana-secret-key.path}"
		"admin:${config.crypt.generated.grafana-admin.path}"
	];

	services.authelia.instances.main.settings.identity_providers.oidc = {
		authorization_policies.pulse = {
			default_policy = "deny";
			rules = [{ policy = "two_factor"; subject = "group:lldap_admin"; }];
		};
		clients = [{
			client_id = "grafana";
			client_name = "pulse";
			# the template filter (on for the oidc key) reads the digest
			client_secret = ''{{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/grafana-oidc-digest" | secret }}'';
			authorization_policy = "pulse";
			require_pkce = true;
			pkce_challenge_method = "S256";
			redirect_uris = [ "https://${pulse}/login/generic_oauth" ];
			scopes = [ "openid" "profile" "email" "groups" ];
			token_endpoint_auth_method = "client_secret_basic";
		}];
	};
	systemd.services.authelia-main.serviceConfig.LoadCredential = [
		"grafana-oidc-digest:${oidc}.digest"
	];

	services.caddy.virtualHosts.${pulse}.extraConfig = ''
		reverse_proxy 127.0.0.1:${toString port}
	'';
}
