# lemma1, a 9front cpu and auth server at 9cule.space (fog.tofu). what's
# declared here goes into an image, which `fog 9 deploy` writes to its disk;
# after that it's 9front's own to change (sysupdate, /lib/ndb/local), and a
# deploy is a reinstall that erases everything on it.
#
# the image is the pinned release's own (./9front.json, `fog 9 pin`),
# installed on lemma1's disk by that release itself, booted in qemu with
# install.rc on its 9fat. it holds no secret: `fog 9 deploy` gives it its
# nvram key and the users' passwords, from `p`, before writing it
let
	pins = builtins.fromJSON (builtins.readFile ../pins.json);
	pkgs = import (fetchTarball {
		inherit (pins.nixpkgs) url sha256;
		name = "source";
	}) { };
	inherit (pkgs) lib;

	release = builtins.fromJSON (builtins.readFile ./9front.json);
	base = pkgs.fetchurl {
		name = "9front-${release.release}.amd64.qcow2.gz";
		inherit (release) url sha256;
	};

	sysname = "lemma1";
	dom = "9cule.space";
	# fog.tofu's dew1_4 and dew1
	ipv4 = "89.167.72.44";
	ipv6 = "2a01:4f9:c015:94dc::1";
	# hetzner's resolvers
	dns = [ "185.12.64.1" "185.12.64.2" ];
	# a cpx02's disk is "20 GB", which may be 10^9 bytes each or 2^30;
	# this fits either. `fog 9 deploy` checks it does
	size = "19000M";

	# the hostowner, whose key is the nvram's: the installer's default
	hostowner = "glenda";
	# who logs in, and the groups they're in beyond their own: adm and sys
	# for sysupdate and the configuration
	users = {
		lux = { id = 10006; groups = [ "adm" "sys" "upas" ]; };
	};
	# everyone whose password `fog 9 deploy` sets, as p's space/9cule/<user>
	accounts = [ hostowner ] ++ lib.attrNames users;

	# gefs' users file (users(6)), inst/mountgefs's with glenda for $user,
	# and the users above in their groups
	members = g: lib.concatStringsSep "," ([ hostowner ]
		++ lib.attrNames (lib.filterAttrs (_: u: lib.elem g u.groups) users));
	table = [
		{ id = -1; name = "adm"; leader = "adm"; }
		{ id = 0; name = "none"; leader = ""; }
		{ id = 1; name = "tor"; leader = "tor"; }
		{ id = 2; name = hostowner; leader = hostowner; }
		{ id = 10000; name = "sys"; leader = ""; }
		{ id = 10001; name = "map"; leader = "map"; }
		{ id = 10002; name = "doc"; leader = ""; }
		{ id = 10003; name = "upas"; leader = "upas"; }
		{ id = 10004; name = "font"; leader = ""; }
		{ id = 10005; name = "bootes"; leader = "bootes"; }
	] ++ lib.mapAttrsToList (name: u: { inherit (u) id; inherit name; leader = name; }) users;
	userfile = lib.concatMapStrings (e: "${toString e.id}:${e.name}:${e.leader}:${
		lib.optionalString (lib.elem e.name [ "adm" "sys" "upas" ]) (members e.name)}\n") table;

	# its own auth server, for 9cule.space: drawterm -h 9cule.space -a
	# 9cule.space -u lux. cpurc starts keyfs and listens for auth (567)
	# when $auth is itself, and rcpu (17019) always
	ndb = lib.concatLines [
		""
		"sys=${sysname} dom=${dom}"
		"\tip=${ipv4} ip=${ipv6}"
		"\t${lib.concatMapStringsSep " " (d: "dns=${d}") dns}"
		"\tauth=${sysname} cpu=${sysname}"
		""
		"authdom=${dom} auth=${sysname}"
	];

	# hetzner routes it a /32, through 172.31.1.1, outside it, and a /64,
	# through fe80::1. cpurc configures nothing itself once an address is
	# set, and its own setup would want lemma1's mac in ndb
	cpurc = lib.concatLines [
		"# lemma1's addresses (lemma1/default.nix in fog)"
		"ip/ipconfig -g 172.31.1.1 ether /net/ether0 ${ipv4} 255.255.255.255"
		"ip/ipconfig -6 ether /net/ether0"
		"ip/ipconfig -g fe80::1 ether /net/ether0 add ${ipv6} /64"
	];

	# the disk is virtio-scsi's sd00 at hetzner as in qemu. gefs' -A, as
	# inst/bootsetup boots it, lets whoever reaches /srv/boot attach as
	# anyone, which only local processes can. the console is hetzner's,
	# a screen and a keyboard; `fog 9 deploy` makes its own boot's a
	# serial line by turning the comment into console=0, a byte in place
	ini = lib.concatLines [
		"bootfile=9pc64"
		"nobootprompt=local!/dev/sd00/fs -A"
		"service=cpu"
		"sysname=${sysname}"
		"# fog 9 deploy turns the next line on for its own boot"
		"#onsole=0"
	];

	fog = pkgs.linkFarm "lemma1-fog" (lib.mapAttrsToList (name: text: {
		inherit name;
		path = pkgs.writeText name text;
	}) {
		users = userfile;
		homes = lib.concatLines (lib.attrNames users);
		inherit ndb cpurc;
		"plan9.ini" = ini;
	} ++ [{ name = "install.rc"; path = ./install.rc; }]);

	# where the plan 9 partition starts, in bytes: its 9fat starts there
	offset = ''$(($(sfdisk -d "$1" | sed -n 's/.*start= *\([0-9]*\).*type=39.*/\1/p') * 512))'';

	tools = with pkgs; [ qemu_kvm mtools util-linux gzip coreutils gnugrep gnused ];
in {
	inherit fog;

	image = pkgs.runCommand "lemma1-${release.release}.raw.gz" {
		nativeBuildInputs = tools;
		requiredSystemFeatures = [ "kvm" ];
	} ''
		fat() { echo ${offset}; }
		# the release, booted as a terminal on a serial line, with fog/
		gunzip -c ${base} >base.qcow2
		qemu-img convert -O raw base.qcow2 tool.raw
		rm base.qcow2
		at=$(fat tool.raw)
		printf '%s\r\n' bootfile=9pc64 console=0 'nobootprompt=local!/dev/sd00/fs' user=glenda >plan9.ini
		mcopy -o -i tool.raw@@$at plan9.ini ::plan9.ini
		mmd -i tool.raw@@$at ::fog
		mcopy -i tool.raw@@$at ${fog}/* ::fog/

		truncate -s ${size} disk.raw
		log=$PWD/console.log
		. ${./console.sh}
		boot -enable-kvm -m 1024 -smp 2 -nic none -device virtio-scsi-pci,id=s \
			-drive file=tool.raw,format=raw,if=none,id=t -device scsi-hd,drive=t,scsi-id=0 \
			-drive file=disk.raw,format=raw,if=none,id=d -device scsi-hd,drive=d,scsi-id=1
		expect 'term% ' 300
		say '9fs 9fat && rc /n/9fat/fog/install.rc'
		expect 'fog: installed' 1800
		expect 'term% ' 60
		halt
		cat console.log

		gzip -1 -c disk.raw >$out
	'';

	# fog 9 deploy: the image, given its secrets, onto lemma1's disk
	deploy = pkgs.writeShellApplication {
		name = "fog-9-deploy";
		runtimeInputs = tools ++ (with pkgs; [ curl jq openssh ]);
		text = ''
			fat() { echo ${offset}; }
			hostowner=${hostowner}
			dom=${dom}
			sysname=${sysname}
			accounts="${toString accounts}"
			${builtins.readFile ./console.sh}
			${builtins.readFile ./deploy.sh}
		'';
	};
}
