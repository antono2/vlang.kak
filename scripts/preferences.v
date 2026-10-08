// Stores per-project run arguments, working directory and target with guarded updates.
module main

import os
import x.json2
import crypto.sha256

struct Project {
mut:
	root   string
	args   []string
	args_set bool
	cwd    string
	target string
}

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn root_for(path string) string {
	mut dir := os.real_path(if os.is_dir(path) { path } else { os.dir(path) })
	for {
		if os.exists(os.join_path(dir, 'v.mod')) || os.exists(os.join_path(dir, '.git')) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir {
			return os.real_path(os.dir(path))
		}
		dir = parent
	}
	return dir
}

fn main() {
	if os.args.len < 3 {
		eprintln('Usage: preferences COMMAND FILE [VALUE...]')
		exit(2)
	}
	command := os.args[1]
	root := root_for(os.args[2])
	config := os.getenv_opt('VLANG_KAK_CONFIG_HOME') or { os.getenv_opt('XDG_CONFIG_HOME') or { os.join_path(os.home_dir(), '.config') } }
	directory := os.join_path(config, 'vlang.kak', 'projects')
	file := os.join_path(directory, sha256.hexhash(root) + '.json')
	if command in ['args', 'cwd', 'target', 'reset'] {
		if !os.is_dir(directory) {
			os.mkdir_all(directory) or { panic(err) }
			os.chmod(directory, 0o700) or { panic(err) }
		}
		os.mkdir(file + '.lock') or { panic('Project preferences are being updated; retry shortly') }
		defer { os.rmdir(file + '.lock') or {} }
	}
	mut project := Project{ root: root }
	if os.exists(file) {
		data := (json2.decode[json2.Any](os.read_file(file) or { panic(err) }) or { panic('Invalid project preferences: ${err}') }).as_map()
		project = Project{ root: data['root'] or { json2.Any('') }.str(), args_set: (data['args_set'] or { json2.Any(false) }).bool(), args: (data['args'] or { json2.Any([]json2.Any{}) }).as_array().map(it.str()), cwd: data['cwd'] or { json2.Any('') }.str(), target: data['target'] or { json2.Any('') }.str() }
		if project.root != root { panic('Project preferences root does not match') }
	}
	if command in ['args', 'cwd', 'target'] {
		values := os.args[3..]
		match command {
			'args' { project.args = values; project.args_set = true }
			'cwd' {
				if values.len != 1 || !os.is_dir(values[0]) { panic('Choose an existing working directory') }
				project.cwd = os.real_path(values[0])
			}
			'target' {
				if values.len != 1 || !os.exists(values[0]) { panic('Choose an existing V file or directory') }
				project.target = os.real_path(values[0])
			}
			else {}
		}
		os.mkdir_all(directory) or { panic(err) }
		os.write_file(file + '.tmp', json2.Any({
			'root':   json2.Any(project.root)
			'args':   json2.Any(project.args.map(json2.Any(it)))
			'args_set': json2.Any(project.args_set)
			'cwd':    json2.Any(project.cwd)
			'target': json2.Any(project.target)
		}).json_str()) or { panic(err) }
		os.mv(file + '.tmp', file) or { panic(err) }
	} else if command == 'reset' {
		if os.exists(file) { os.rm(file) or { panic(err) } }
		project = Project{ root: root }
	} else if command == 'show' {
		println('Project: ${root}\nPreferences: ${file}\nWorking directory: ${project.cwd}\nTarget: ${project.target}\nArguments: ${project.args}')
		println('\nUse :v-project-arguments ARG... (Kakoune quoting), :v-project-directory PATH, :v-project-target PATH or :v-project-reset.')
		return
	} else if command == 'targets' {
		files := os.walk_ext(root, '.v')
		for path in files {
			if path.contains('/.git/') || path.ends_with('_test.v') {
				continue
			}
			content := os.read_file(path) or { continue }
			if content.contains('fn main(') { println(path) }
		}
		return
	} else if command == 'load' && !os.exists(file) {
		return
	} else if command != 'load' { panic('Unknown project preference command') }
	args := project.args.map(quote(it)).join(' ')
	if project.args_set { println('set-option buffer v_project_args ${args}\nset-option buffer v_debug_args ${args}') } else { println('unset-option buffer v_project_args\nunset-option buffer v_debug_args') }
	println('set-option buffer v_project_cwd ${quote(project.cwd)}')
	if project.cwd == '' { println('unset-option buffer v_debug_cwd') } else { println('set-option buffer v_debug_cwd ${quote(project.cwd)}') }
	println('set-option buffer v_project_target ${quote(project.target)}')
}
