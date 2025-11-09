let
	keys = builtins.fromJSON (builtins.readFile ./keys.json);
	map = user: keys: {
		isNormalUser = true;
		openssh.authorizedKeys.keys = keys;
	};
in {
	users.users = builtins.mapAttrs map keys;
	security.polkit = {
		enable = true;
		extraConfig = ''
			polkit.addRule(function(action, subject) {
				if ((action.id == "org.freedesktop.systemd1.manage-units" ||
						 action.id.indexOf("org.freedesktop.login1.") == 0) &&
						subject.isInGroup("wheel")) {
					return polkit.Result.YES;
				}
			});
		'';
	};
}
