// Verify the paths setup will claim before building or downloading any tools.
module setupconfig

import managedfiles { repair, settings_block }
import os

const block_end = '# <<< vlang.kak managed <<<'

fn regular_file(path string) bool {
	info := os.stat(path) or { return false }
	return info.get_filetype() == .regular
}

pub fn check_personal(config_home string, repo_dir string) ! {
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

pub fn check_managed(prefix string) ! {
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

pub fn verify_paths(phase string, prefix string, repo string, config_home string, integrate bool) ! {
	if phase != 'managed' && integrate {
		check_personal(config_home, repo)!
	}
	if phase != 'personal' {
		check_managed(prefix)!
	}
}

pub fn prepare_paths(prefix string, repo string, config_home string, integrate bool, repair_links bool, update bool) !int {
	if repair_links {
		verify_paths('personal', prefix, repo, config_home, integrate)!
		repair(os.norm_path(prefix))!
		verify_paths('managed', prefix, repo, config_home, integrate)!
	} else {
		verify_paths('all', prefix, repo, config_home, integrate)!
	}
	if update && os.getenv('VLANG_KAK_SKIP_PULL') != '1' {
		return refresh(repo)
	}
	return 0
}
