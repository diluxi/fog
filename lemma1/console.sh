# sourced: drives a 9front booted in qemu through its serial console, in
# the current directory. the console's output goes to $log; `expect` waits
# for text in what came after the last text it waited for, and `say` sends
# a line, as if typed

qemu=

# boot [args...]: qemu, with the console here
boot() {
	rm -f console.in
	mkfifo console.in
	: >"$log"
	pos=0
	qemu-system-x86_64 -nographic -no-reboot -monitor none -serial stdio \
		"$@" <console.in >>"$log" 2>&1 &
	qemu=$!
	exec 3>console.in
}

expect() {
	_t=${2:-600}
	until _found=$(tail -c +$((pos + 1)) "$log" | grep -boF -m 1 -- "$1" | cut -d: -f1) &&
		[ -n "$_found" ]; do
		if ! kill -0 "$qemu" 2>/dev/null || [ "$_t" -le 0 ]; then
			echo "console: no \"$1\"; it said:" >&2
			tail -c +$((pos + 1)) "$log" | tr -d '\r' | tail -n 40 >&2
			exit 1
		fi
		sleep 1
		_t=$((_t - 1))
	done
	pos=$((pos + _found + ${#1}))
}

say() {
	printf '%s\n' "$1" >&3
}

# after fshalt -r, qemu goes, since it doesn't reboot
halt() {
	say 'fshalt -r'
	wait "$qemu"
	qemu=
	exec 3>&-
}

# what's left of qemu after a failure
stop() {
	[ -z "$qemu" ] || kill "$qemu" 2>/dev/null || :
}
