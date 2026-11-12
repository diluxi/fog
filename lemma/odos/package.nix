{ lib, stdenvNoCC, sbcl, makeWrapper, python3Packages, curl, ffmpeg-headless }: let
	lisp = sbcl.withPackages (ps: [ ps.com_dot_inuoe_dot_jzon ps.cl-ppcre ]);
in stdenvNoCC.mkDerivation {
	pname = "odos";
	version = "0";
	src = lib.fileset.toSource {
		root = ./.;
		fileset = lib.fileset.unions [ ./odos.asd ./odos.lisp ];
	};
	nativeBuildInputs = [ lisp makeWrapper ];
	# an image with odos and jzon in it, which starts in odos:main and
	# leaves the command line to it
	buildPhase = ''
		runHook preBuild
		export HOME=$TMPDIR
		sbcl --non-interactive --no-userinit \
			--eval '(require :asdf)' \
			--eval '(asdf:load-asd (truename "odos.asd"))' \
			--eval '(asdf:load-system "odos")' \
			--eval '(sb-ext:save-lisp-and-die "odos" :executable t :toplevel (function odos:main) :save-runtime-options t :compression t)'
		runHook postBuild
	'';
	# guessit reads the names, ffprobe the files, curl tells jellyfin
	installPhase = ''
		runHook preInstall
		install -Dm755 odos $out/bin/odos
		wrapProgram $out/bin/odos --prefix PATH : ${lib.makeBinPath [ python3Packages.guessit ffmpeg-headless curl ]}
		runHook postInstall
	'';
	# the image is sbcl's runtime with a core appended; stripping cuts it off
	dontStrip = true;
	meta.mainProgram = "odos";
}
