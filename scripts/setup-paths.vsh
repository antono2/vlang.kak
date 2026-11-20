// Verify the paths setup will claim before building or downloading any tools.
import managedfiles { settings_block }
import os

const block_end = '# <<< vlang.kak managed <<<'

fn regular_file(path string) bool {
	info := os.stat(path) or { return false }
	return info.get_filetype() == .regular
}

fn check_personal(config_home string, repo_dir string) ! {
	kak := os.join_path(config_home, 'kak')
	kakrc := os.join_path(kak, 'kakrc')
	if os.is_link(kakrc) && !os.exists(kakrc) {
		return error('Broken kakrc link: ${kakrc}')
	}
	if regular_file(kakrc) {
		block := settings_block(kakrc) or { return error('Malformed managed block in ${kakrc}') }
		if block_end in block.remaining.split('\n') {
			return error('Malformed managed block in ${kakrc}')
		}
	}
	for item in ['vlang.kak', 'vlang-site-runtime'] {
		link := os.join_path(kak, 'autoload', item)
		linked := os.is_link(link)
		if os.exists(link) && !linked {
			return error('Existing unmanaged autoload entry: ${link}')
		}
		if item == 'vlang.kak' && linked && os.real_path(link) != os.join_path(repo_dir, 'rc', item) {
			return error('Conflicting plugin link: ${link}')
		}
	}
}

fn check_managed_file(path string, marker string) ! {
	if os.is_link(path)
		|| (os.exists(path) && (!regular_file(path) || marker !in os.read_file(path)!.split('\n'))) {
		return error('Existing unmanaged file: ${path}. Choose another --prefix or move it yourself.')
	}
}

fn check_managed(prefix string) ! {
	install := os.join_path(prefix, 'opt', 'vlang-kakoune')
	bin := os.join_path(prefix, 'bin')
	if os.is_dir(os.join_path(install, 'current', 'share', 'kak')) {
		check_managed_file(os.join_path(bin, 'kak'), '# vlang.kak managed Kakoune launcher')!
	}
	check_managed_file(os.join_path(bin, 'kak-v'), '# vlang.kak managed IDE launcher')!
	isolated := os.join_path(install, 'ide-config', 'kak')
	check_managed_file(os.join_path(isolated, 'kakrc'),
		'# vlang.kak managed isolated configuration')!
	for item in ['vlang.kak', 'vlang-site-runtime'] {
		link := os.join_path(isolated, 'autoload', item)
		if os.exists(link) && !os.is_link(link) {
			return error('Existing unmanaged autoload entry: ${link}. Choose another --prefix.')
		}
	}
}

fn verify(args []string) ! {
	phase, prefix, repo_dir, config_home, integrate := args[0], args[1], args[2], args[3], args[4]
	if phase != 'managed' && integrate == 'true' {
		check_personal(config_home, repo_dir)!
	}
	if phase != 'personal' {
		check_managed(prefix)!
	}
}

fn main() {
	if os.args.len != 6 || os.args[1] !in ['all', 'personal', 'managed'] {
		eprintln('Usage: setup-paths.vsh all|personal|managed PREFIX REPO CONFIG_HOME INTEGRATE')
		exit(2)
	}
	verify(os.args[1..]) or {
		eprintln(err)
		exit(1)
	}
}
