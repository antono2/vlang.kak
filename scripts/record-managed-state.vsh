// Record owned tool and editor files without adopting additions to existing releases.
import managedrecord
import os

const usage = 'Usage: v run scripts/record-managed-state.vsh PREFIX CONFIG_HOME [VLS_MODE]'

if os.args[1..].any(it in ['--help', '-h']) {
	println(usage)
	exit(0)
}
if os.args.len !in [3, 4] {
	eprintln(usage)
	exit(2)
}
managedrecord.record(os.args[1], os.args[2], os.args[3] or { '' }) or {
	eprintln(err)
	exit(1)
}
