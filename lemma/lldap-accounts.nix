{ config, lib, pkgs, ... }: let
	cfg = config.lldap;
	settings = config.services.lldap.settings;
	baseDN = settings.ldap_base_dn;
	people = "ou=people,${baseDN}";
	http = "http://${settings.http_host}:${toString settings.http_port}";
	ldap = "ldap://${settings.ldap_host}:${toString settings.ldap_port}";
	domain = lib.last (lib.splitString "@" settings.ldap_user_email);

	# root's password: lldap resets root to it at every start, and only this
	# provisioner logs in with it
	root = config.crypt.generated.lldap-root.path;

	account = name: groups: ''
		ensure ${lib.escapeShellArgs ([ name cfg.serviceAccounts.${name}.passwordFile ] ++ groups)}
	'';

	# makes each account exist, puts it in its groups (never takes it out of
	# others) and sets its password to the generated one. graphql for the
	# account and groups, ldap's password modify for the password, so neither
	# password nor token ever shows up on a command line
	provision = pkgs.writeShellScript "lldap-accounts" ''
		set -euo pipefail
		hdr=$(mktemp)
		trap 'rm -f "$hdr"' EXIT

		jq -nc --rawfile p ${root} '{username: "root", password: $p}' |
			curl -sSf --retry 30 --retry-connrefused --retry-delay 1 \
				-H 'content-type: application/json' --data @- \
				${http}/auth/simple/login |
			jq -r '"Authorization: Bearer \(.token)"' >"$hdr"

		gql() {
			jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' |
				curl -sSf -H @"$hdr" -H 'content-type: application/json' \
					--data @- ${http}/api/graphql |
				jq -ce 'if .errors then error(.errors[0].message) else .data end'
		}

		groups=$(gql 'query { groups { id displayName } }' '{}')
		for g in ${lib.escapeShellArgs cfg.groups}; do
			jq -e --arg g "$g" '.groups | any(.displayName == $g)' \
				<<<"$groups" >/dev/null && continue
			echo "creating group $g"
			gql 'mutation($n: String!) { createGroup(name: $n) { id } }' \
				"$(jq -nc --arg n "$g" '{$n}')" >/dev/null
		done
		groups=$(gql 'query { groups { id displayName } }' '{}')

		ensure() {
			local id=$1 password=$2 have g gid
			shift 2
			if ! have=$(gql 'query($id: String!) {
				user(userId: $id) { groups { displayName } }
			}' "$(jq -nc --arg id "$id" '{$id}')" 2>/dev/null); then
				echo "creating $id"
				gql 'mutation($u: CreateUserInput!) { createUser(user: $u) { id } }' \
					"$(jq -nc --arg id "$id" --arg mail "$id@${domain}" \
						'{u: {id: $id, email: $mail, displayName: $id}}')" >/dev/null
				have='{"user": {"groups": []}}'
			fi
			for g; do
				jq -e --arg g "$g" '.user.groups | any(.displayName == $g)' \
					<<<"$have" >/dev/null && continue
				gid=$(jq -e --arg g "$g" '.groups[] | select(.displayName == $g) | .id' \
					<<<"$groups") || { echo "no group $g" >&2; return 1; }
				echo "adding $id to $g"
				gql 'mutation($u: String!, $g: Int!) {
					addUserToGroup(userId: $u, groupId: $g) { ok }
				}' "$(jq -nc --arg u "$id" --argjson g "$gid" '{$u, $g}')" >/dev/null
			done
			ldappasswd -x -H ${ldap} -D uid=root,${people} -y ${root} \
				-T "$password" "uid=$id,${people}"
		}

		${lib.concatStrings (lib.mapAttrsToList (name: a: account name a.groups)
			cfg.serviceAccounts)}
	'';
in {
	# groups to create if missing. their members are people, managed in the
	# ui; only service accounts' memberships are declared
	options.lldap.groups = lib.mkOption {
		type = lib.types.listOf lib.types.str;
		default = [];
	};

	options.lldap.serviceAccounts = lib.mkOption {
		description = ''
			LLDAP accounts for services, each with a password generated on the
			machine (crypt.generated.lldap-<name>) and set by lldap-accounts.
			Services that bind as one should order after lldap-accounts.
		'';
		default = {};
		type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
			options = {
				groups = lib.mkOption {
					type = lib.types.listOf lib.types.str;
					default = [];
					example = [ "lldap_strict_readonly" ];
				};
				dn = lib.mkOption {
					type = lib.types.str;
					default = "uid=${name},${people}";
					readOnly = true;
				};
				passwordFile = lib.mkOption {
					type = lib.types.str;
					default = config.crypt.generated."lldap-${name}".path;
					readOnly = true;
				};
			};
		}));
	};

	config = lib.mkIf config.services.lldap.enable {
		crypt.generated = {
			lldap-root = {};
		} // lib.mapAttrs' (name: _: lib.nameValuePair "lldap-${name}" {})
			cfg.serviceAccounts;

		systemd.services.lldap.serviceConfig.LoadCredential = [ "root:${root}" ];
		services.lldap.environment.LLDAP_LDAP_USER_PASS_FILE = "%d/root";

		systemd.services.lldap-accounts = {
			description = "lldap service accounts";
			wantedBy = [ "multi-user.target" ];
			requires = [ "lldap.service" ];
			after = [ "lldap.service" ];
			path = with pkgs; [ curl jq openldap ];
			serviceConfig = {
				Type = "oneshot";
				RemainAfterExit = true;
				ExecStart = provision;
			};
		};
	};
}
