// Validate setup paths and prepare the checkout before downloading tools.
import managedfiles
import os
import setupconfig

fn verify(phase string, prefix string, repo string, config_home string, integrate bool) ! {
	if phase != 'managed' && integrate {
		setupconfig.check_personal(config_home, repo)!
	}
	if phase != 'personal' {
		setupconfig.check_managed(prefix)!
	}
}

fn prepare(prefix string, repo string, config_home string, integrate bool, repair bool, update bool) !int {
	if repair {
		verify('personal', prefix, repo, config_home, integrate)!
		managedfiles.repair(os.norm_path(prefix))!
		verify('managed', prefix, repo, config_home, integrate)!
	} else {
		verify('all', prefix, repo, config_home, integrate)!
	}
	if update && os.getenv('VLANG_KAK_SKIP_PULL') != '1' {
		return setupconfig.refresh(repo)
	}
	return 0
}

fn main() {
	args := os.args[1..]
	if args.len == 7 && args[0] == '--prepare' && args[5..].all(it in ['true', 'false']) {
		exit(prepare(args[1], args[2], args[3], args[4] == 'true', args[5] == 'true',
			args[6] == 'true') or {
			eprintln(err)
			1
		})
	}
	if args.len != 5 || args[0] !in ['all', 'personal', 'managed'] {
		eprintln('Usage: setup-paths.vsh {all|personal|managed} PREFIX REPO CONFIG_HOME INTEGRATE')
		exit(2)
	}
	verify(args[0], args[1], args[2], args[3], args[4] == 'true') or {
		eprintln(err)
		exit(1)
	}
}
