{ config, lib, pkgs, ... }: let
	# komf (snd-r's komga and kavita metadata fetcher): series metadata and
	# covers for kavita's libraries (lemma/shelf.nix), from mangaupdates,
	# anilist, mangadex and mangabaka. a release's jar, which needs a jre
	komf = pkgs.stdenvNoCC.mkDerivation rec {
		pname = "komf";
		version = "2.1.0";
		src = pkgs.fetchurl {
			url = "https://github.com/Snd-R/komf/releases/download/${version}/komf-${version}.jar";
			hash = "sha256-J2AitFV42TPoBHvmO/3UEjyAl53tiy8JhlB/2vCEAJM=";
		};
		dontUnpack = true;
		nativeBuildInputs = [ pkgs.makeWrapper ];
		installPhase = ''
			install -Dm644 $src $out/share/komf/komf.jar
			makeWrapper ${lib.getExe pkgs.jre_headless} $out/bin/komf \
				--add-flags "-jar $out/share/komf/komf.jar"
		'';
		meta.mainProgram = "komf";
	};

	port = 8085;
	kavita = "http://127.0.0.1:${toString config.services.kavita.settings.Port}";

	# where each of kavita's libraries looks: a kind, as komf matches book
	# numbers by it, and providers. comics have none: what knows western
	# comics is comicvine, which wants an api key
	providers = mediaType: {
		mangaUpdates = { priority = 10; enabled = true; inherit mediaType; };
		aniList = { priority = 20; enabled = true; inherit mediaType; };
		mangaDex = { priority = 30; enabled = mediaType != "NOVEL"; inherit mediaType; };
		mangaBaka = { priority = 40; enabled = true; inherit mediaType; mode = "API"; };
	};
	libraries = {
		Manga = { libraryType = "MANGA"; providers = providers "MANGA"; };
		Books = { libraryType = "NOVEL"; providers = providers "NOVEL"; };
	};

	# komf's application.yml (json is yaml), but for what's by library id,
	# which only kavita knows: the start adds those
	settings = {
		kavita = {
			baseUri = kavita;
			# new series in the libraries above are matched as kavita finds them
			eventListener.enabled = true;
			metadataUpdate.default = {
				# through kavita's api only: COMIC_INFO would write into the
				# archives, which are torrents being seeded
				updateModes = [ "API" ];
				# the first match, with what it lacks from the others
				aggregate = true;
				mergeTags = true;
				mergeGenres = true;
				# kavita's covers are a first page; a provider's is the cover
				seriesCovers = true;
				overrideExistingCovers = true;
				lockCovers = true;
				postProcessing = {
					alternativeSeriesTitles = true;
					alternativeSeriesTitleLanguages = [ "en" "ja" "ja-ro" ];
				};
			};
		};
		# nothing anywhere unless a library says
		metadataProviders.defaultProviders = {};
		server.port = port;
		logLevel = "INFO";
		# okhttp's default logs every url, and kavita's authentication has
		# fog's api key in its query
		httpLogLevel = "NONE";
	};
in {
	systemd.services.komf = {
		description = "metadata for kavita's series";
		wantedBy = [ "multi-user.target" ];
		requires = [ "kavita.service" ];
		after = [ "kavita.service" "kavita-setup.service" "network-online.target" ];
		wants = [ "kavita-setup.service" "network-online.target" ];
		path = with pkgs; [ curl jq ];
		environment = {
			KOMF_CONFIG_DIR = "/var/lib/komf";
			# small and seldom busy: a smaller heap, given back when idle
			JAVA_TOOL_OPTIONS = "-Xmx512m -XX:+UnlockExperimentalVMOptions -XX:+UseShenandoahGC -XX:ShenandoahGCHeuristics=compact"
				+ " -XX:ShenandoahGuaranteedGCInterval=3600000 -XX:TrimNativeHeapInterval=3600000";
		};
		# as kavita's admin fog, whose api key komf uses, and the libraries'
		# ids. the key stays in komf's environment, the file has none
		script = ''
			set -o pipefail
			api=${kavita}/api
			for i in $(seq 120); do curl -sf $api/health >/dev/null && break; sleep 1; done
			login=$(jq -nc --rawfile p "$CREDENTIALS_DIRECTORY/admin" '{username: "fog", password: $p}' |
				curl -sSf -H 'content-type: application/json' --data @- $api/account/login)
			token=$(jq -r .token <<<"$login")
			export KOMF_KAVITA_API_KEY=$(jq -r .apiKey <<<"$login")
			unset login

			# config's settings, with each library above by its id. what komf's
			# ui changes is written there too, and lasts until the next start
			curl -sSf -H "Authorization: Bearer $token" $api/library/libraries |
				jq --argjson want ${lib.escapeShellArg (builtins.toJSON libraries)} \
					--argjson settings ${lib.escapeShellArg (builtins.toJSON settings)} '
					[ .[] | select($want[.name]) | { id: (.id | tostring), want: $want[.name] } ] as $libs
					| $settings
					| .kavita.eventListener.metadataLibraryFilter = [ $libs[].id ]
					| .kavita.metadataUpdate.library = ($libs | map({ (.id): ($settings.kavita.metadataUpdate.default
						+ { libraryType: .want.libraryType }) }) | add // {})
					| .metadataProviders.libraryProviders = ($libs | map({ (.id): .want.providers }) | add // {})
				' >"$STATE_DIRECTORY/application.yml"
			unset token
			exec ${lib.getExe komf}
		'';
		serviceConfig = {
			DynamicUser = true;
			StateDirectory = "komf";
			StateDirectoryMode = "0700";
			LoadCredential = [ "admin:${config.crypt.generated.kavita-admin.path}" ];
			Restart = "on-failure";
			RestartSec = "30s";
			PrivateTmp = true;
			ProtectSystem = "strict";
			ProtectHome = true;
			NoNewPrivileges = true;
			RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
		};
	};

	# komf listens on every address, and its api has no login: it changes
	# its own config and kavita's metadata with fog's key. only loopback
	# and the admin role's peers reach it (http://10.10.1.1:8085), the
	# admins of everything else too; not other trusted interfaces like fog
	networking.nftables.tables.komf = {
		family = "inet";
		content = ''
			chain input {
				type filter hook input priority filter - 1; policy accept;
				tcp dport ${toString port} iifname != { "lo", "${config.vpn.roles.admin.interface}" } drop
			}
		'';
	};
}
