let
	fetchGitHub = repo: { ref, sha256, ... }: fetchTarball {
		inherit sha256;
		name = "source";
		url = "https://github.com/${repo}/archive/${ref}.tar.gz";
	};

	disko = fetchGitHub "nix-community/disko" {
		ref = "af087d076d3860760b3323f6b583f4d828c1ac17";
		sha256 = "1lyp1myii1gmvx8n6j7m1c9dvap1630hqgkp082zvnd9z600zmsf";
	};

	pkgs = fetchGitHub "nixos/nixpkgs" {
		ref = "b3d51a0365f6695e7dd5cdf3e180604530ed33b4";
		sha256 = "1p015n2jb2sjx15cny60kch4d6k59ff0xrxa51kacrffkswl7y72";
	};
in import (pkgs + "/nixos/lib/eval-config.nix") {
	modules = [
		"${disko}/module.nix"
		./users
		./lemma
	];
}
