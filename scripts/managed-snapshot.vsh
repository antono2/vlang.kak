// Capture and restore the managed files shared by setup and rollback.
import managedsnapshot
import os

fn main() {
	if os.args.len != 4 || !os.is_abs_path(os.args[2]) || os.args[3] == '' {
		eprintln('Usage: managed-snapshot.vsh snapshot|snapshot-personal|restore ABSOLUTE_ROOT DIRECTORY')
		exit(2)
	}
	root := os.real_path(os.args[2])
	directory := os.abs_path(os.args[3])
	match os.args[1] {
		'snapshot' { managedsnapshot.capture(root, directory) or { fatal(err) } }
		'snapshot-personal' { managedsnapshot.capture_personal(root, directory) or { fatal(err) } }
		'restore' { managedsnapshot.restore(root, directory) or { fatal(err) } }
		else { fatal(error('Unknown snapshot operation.')) }
	}
}

fn fatal(err IError) {
	eprintln(err)
	exit(1)
}
