# the rest of fog-9-deploy (lemma1/default.nix), which sets $hostowner,
# $dom, $sysname, $accounts and fat(), after console.sh. fog passes the
# image, the hetzner token as $HCLOUD_TOKEN and tofu's output lemma1 as
# $LEMMA1. passwords are p's space/9cule/<user>, first line. with -n, the
# image with its keys is left in ./lemma1.raw instead, to boot in qemu

dry=
[ "$1" = -n ] && { dry=1; shift; }
image=$1
here=$PWD

declare -A pass
for u in $accounts; do
	pass[$u]=$(p show "space/9cule/$u" | head -n 1)
	[ -n "${pass[$u]}" ] || { echo "fog 9: no password in space/9cule/$u" >&2; exit 1; }
done

if [ -z "$dry" ]; then
	server=$(jq -r .id <<<"$LEMMA1")
	ipv4=$(jq -r .ipv4 <<<"$LEMMA1")
	key=$(jq -r .ssh_key <<<"$LEMMA1")
	printf 'this erases everything on %s (hetzner server %s); type its name: ' "$sysname" "$server" >&2
	read -r answer </dev/tty
	[ "$answer" = "$sysname" ] || { echo "fog 9: not deploying" >&2; exit 1; }
fi

work=$(mktemp -d)
trap 'stop; rm -rf "$work"' EXIT
cd "$work"

# the image, booted here once on a serial line: its nvram key, which the
# cpu server asks for at boot when it has none, and every account's key in
# keyfs, which cpurc starts, it being its own auth server
echo "fog 9: giving the image its keys" >&2
gunzip -c "$image" | dd of=disk.raw bs=1M conv=sparse status=none
at=$(fat disk.raw)

# plan9.ini's console line, switched by its first byte, in place: 9boot
# may read a file that mtools rewrote by its old directory entry, and so
# with its old length
console() {
	n=$(head -c $((at + 100 * 1024 * 1024)) disk.raw | tail -c +$((at + 1)) |
		grep -obaF -- "$1" | cut -d: -f1)
	[ "$(wc -l <<<"$n")" = 1 ] && [ -n "$n" ] ||
		{ echo "fog 9: no one \"$1\" in the 9fat" >&2; exit 1; }
	printf %s "$2" | dd of=disk.raw bs=1 seek=$((at + n)) conv=notrunc status=none
}
console '#onsole=0' c

# passwords aren't echoed; the log is the console's
log=$work/console.log
boot -enable-kvm -m 1024 -smp 2 -nic none -device virtio-scsi-pci,id=s \
	-drive file=disk.raw,format=raw,if=none,id=d -device scsi-hd,drive=d
expect 'authid: ' 300; say "$hostowner"
expect 'authdom: ' 30; say "$dom"
expect 'secstore key: ' 30; say ''
expect 'password: ' 30; say "${pass[$hostowner]}"
expect 'confirm password: ' 30; say "${pass[$hostowner]}"
expect 'enable legacy p9sk1[no]: ' 30; say ''
expect "$sysname# " 300
for u in $accounts; do
	say "auth/changeuser -p $u"
	expect 'Password: ' 30; say "${pass[$u]}"
	expect 'Confirm password: ' 30; say "${pass[$u]}"
	expect 'secret? [y/n]: ' 30; say n
	# no expiry, and none of what it asks about the user (querybio.c),
	# each answered as asked: what's typed ahead is lost
	for q in 'Expiration date' 'Post id' "User's full name" 'Department #' \
		"User's email address" "Sponsor's email address"; do
		expect "$q" 30; say ''
	done
	expect "user $u installed for Plan 9" 30
	expect "$sysname# " 30
done
halt
console 'console=0' '#'
if [ -n "$dry" ]; then
	cp --sparse=always disk.raw "$here/$sysname.raw"
	echo "fog 9: $here/$sysname.raw" >&2
	exit
fi

# hetzner's rescue system, with lux's key, from which the image goes onto
# the disk. it has a new host key every time and hetzner doesn't say which
api() {
	curl -sSf -H "Authorization: Bearer $HCLOUD_TOKEN" -H 'Content-Type: application/json' \
		"https://api.hetzner.cloud/v1/$1" ${2:+-X POST -d "$2"}
}
act() {
	body=${2-}
	[ -n "$body" ] || body='{}'
	id=$(api "servers/$server/actions/$1" "$body" | jq -r .action.id)
	while :; do
		case $(api "actions/$id" | jq -r .action.status) in
		success) return ;;
		error) echo "fog 9: $1 failed" >&2; exit 1 ;;
		esac
		sleep 2
	done
}
rescue() {
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		-o ConnectTimeout=5 "root@$ipv4" "$@"
}

echo "fog 9: booting $sysname's rescue system" >&2
act enable_rescue "{\"type\":\"linux64\",\"ssh_keys\":[$key]}"
act reset
tries=60
until rescue true 2>/dev/null; do
	tries=$((tries - 1))
	[ $tries -gt 0 ] || { echo "fog 9: the rescue system never answered" >&2; exit 1; }
	sleep 5
done

have=$(rescue blockdev --getsize64 /dev/sda)
need=$(stat -c %s disk.raw)
[ "$have" -ge "$need" ] || { echo "fog 9: the disk has $have bytes, the image $need" >&2; exit 1; }

echo "fog 9: writing the image" >&2
gzip -1 -c disk.raw | rescue 'gunzip | dd of=/dev/sda bs=4M conv=fsync status=progress'
# the rescue system is only for one boot
act reset
echo "fog 9: $sysname boots 9front: drawterm -h $dom -a $dom -u <user>" >&2
