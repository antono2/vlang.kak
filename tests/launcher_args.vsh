// Check argument boundaries and mode detection in both managed launchers.
import os
import rand
import releasetest { capture_result }
import x.json2

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-launcher-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	os.symlink(os.executable(), os.join_path(bin, 'kak'))!
	os.mkdir_all(os.join_path(root, 'opt', 'vlang-kakoune'))!
	project := os.join_path(root, "project's %{literal} \$HOME")
	os.mkdir(project)!
	helper := os.join_path(os.dir(@DIR), 'scripts', 'helper-cache.sh')
	posix := os.join_path(os.dir(@DIR), 'scripts', 'launcher-posix')
	mut env := os.environ()
	env['PATH'] = bin + ':' + env['PATH']
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache')
	env['VLANG_KAK_PREFIX'] = root
	for launcher in [helper, posix] {
		for args in [[project, '-e', 'echo custom'], ['--', project], ['-e', '-d', 'main.v'],
			['-s', project, 'main.v'], ['-d', '-s', project], []string{}] {
			mut invocation := if launcher == helper { ['launcher'] } else { []string{} }
			invocation << args
			result := capture_result(launcher, invocation, environment: env, work_folder: project)!
			assert result.code == 0, result.stderr
			value := json2.decode[json2.Any](result.stdout)!.as_map()
			actual := (value['args'] or { json2.Any([]json2.Any{}) }).as_array().map(it.str())
			allowed := (value['allowed'] or { json2.Any('') }).str()
			if args == ['-d', '-s', project] {
				assert actual == args && allowed == '0'
			} else if (args.contains(project) && args[0] != '-s') || args.len == 0 {
				assert actual.len == 2 && actual[0] == '-e'
				assert actual[1].starts_with("v-workspace-start '${project.replace("'", "''")}'")
				if args.contains('echo custom') {
					assert actual[1].ends_with('\necho custom')
				}
				assert allowed == '1'
			} else {
				assert actual.contains('main.v') && allowed == '1'
				if args[0] == '-s' {
					assert actual == args
				}
			}
		}
	}
	println('ok - V and shell launchers preserve quoted paths, option values, --, startup commands and server modes')
}

if os.file_name(os.args[0]) == 'kak' {
	println(json2.encode({
		'args':    json2.Any(os.args[1..].map(json2.Any(it)))
		'allowed': json2.Any(os.getenv('VLANG_KAK_RESTART_ALLOWED'))
	}))
} else {
	check() or {
		eprintln(err)
		exit(1)
	}
}
