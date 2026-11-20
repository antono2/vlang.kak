// Activate prepared tool releases for direct callers and diagnostics.
import os
import setupconfig

if os.args.len != 4 || !os.is_abs_path(os.args[1])
	|| os.args[2] !in ['upstream', 'external', 'skip'] {
	eprintln('Usage: v run scripts/setup-activation.vsh ABSOLUTE_PREFIX VLS_MODE VLS_PATH')
	exit(2)
}
setupconfig.activate(os.real_path(os.abs_path(os.args[1])), os.args[2], os.args[3]) or {
	eprintln(err)
	exit(1)
}
