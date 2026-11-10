{ lib, buildGoModule, buildNpmPackage, fetchFromGitHub, dart-sass }: let
	version = "2.3.1";
	src = fetchFromGitHub {
		owner = "h44z";
		repo = "wg-portal";
		rev = "v${version}";
		hash = "sha256-nkDCEtG4gYv/8pppJtlGQcHhuupL9nnw90XKxRym5gA=";
	};

	# the vue frontend, which the go binary embeds
	frontend = buildNpmPackage {
		pname = "wg-portal-frontend";
		inherit version src;
		sourceRoot = "${src.name}/frontend";
		npmDepsFetcherVersion = 2;
		npmDepsHash = "sha256-68ssx2nHFI5fjIDUxi93ajpedW73qQOzUN1sXtKENrk=";
		env.DIST_OUT_DIR = "dist";
		# sass-embedded's own dart doesn't run on nixos; nixpkgs' dart-sass,
		# as bazarr does (https://github.com/sass/embedded-host-node/issues/334)
		nativeBuildInputs = [ dart-sass ];
		preBuild = ''
			substituteInPlace node_modules/sass-embedded/dist/lib/src/compiler-path.js \
				--replace-fail 'compilerCommand = (() => {' 'compilerCommand = (() => { return ["dart-sass"];'
		'';
		installPhase = "cp -r dist $out";
	};
in buildGoModule {
	pname = "wg-portal";
	inherit version src;
	vendorHash = "sha256-Dkn+tSKktPfcOxNY7Ogp5ame8c9WH1goIFTFKJpm4sk=";
	subPackages = [ "cmd/wg-portal" ];
	env.CGO_ENABLED = 0;
	ldflags = [ "-s" "-w" "-X github.com/h44z/wg-portal/internal.Version=v${version}" ];
	preBuild = ''
		rm -rf internal/app/api/core/frontend-dist
		cp -r ${frontend} internal/app/api/core/frontend-dist
	'';
	meta.license = lib.licenses.mit;
}
