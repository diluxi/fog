let
	pins = builtins.mapAttrs (_: { url, sha256 }: fetchTarball {
		inherit url sha256;
		name = "source";
	}) (builtins.fromJSON (builtins.readFile ./pins.json));
in import (pins.nixpkgs + "/nixos/lib/eval-config.nix") {
	modules = [
		"${pins.disko}/module.nix"
		./crypt.nix
		./users
		./lemma
	];
}
