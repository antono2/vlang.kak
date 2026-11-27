// Render directory startup commands without evaluating stored text as code.
import os
import workspacefiles

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn run(args []string) ! {
	if args.len != 3 {
		return error('Expected open|remember ROOT RESTORE|FILE')
	}
	if args[0] == 'open-start' && os.getenv('VLANG_KAK_RESTART_SOURCE') != '' {
		// Replay owns the selected directory and buffers, even if the original
		// CLI directory was moved or another workspace was selected later.
		return
	}
	root := os.real_path(args[1])
	if !os.is_dir(root) {
		return error('Choose an existing project directory')
	}
	if args[0] == 'remember' {
		workspacefiles.remember(root, args[2])!
		return
	}
	if args[0] !in ['open', 'open-start'] {
		return error('Unknown workspace action')
	}
	file := workspacefiles.initial_file(root, args[2] == 'true')
	println('set-option global v_workspace_root ' + quote(root))
	println('cd ' + quote(root))
	if file != '' {
		println('edit -existing -- ' + quote(file))
	} else {
		println('edit -scratch ' + quote('*project*'))
		println("echo 'No v.mod or recent file; choose a file in the project tree'")
	}
	println('v-workspace-show-tree')
}

fn main() {
	run(os.args[1..]) or {
		eprintln(err)
		exit(1)
	}
}
