// Exercise the proposal script with a local bare Git remote and a GitHub CLI stand-in.
import os
import rand
import releasetest { capture }

const old_pin = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
const new_pin = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
const proposal_branch = 'automation/kakoune-${new_pin}'
const base = 'master'
const pin_path = 'tests/release.env'
const list_args = ['pr', 'list', '--head', proposal_branch, '--state', 'all', '--json', 'number']
const create_args = ['pr', 'create', '--base', base, '--head', proposal_branch, '--title',
	'Update verified Kakoune master revision', '--body-file']
const workflow_args = ['workflow', 'run', 'test.yml', '--ref', proposal_branch]

fn release_env(pin string) string {
	return '# Release fixture\nKAKOUNE_VERSION=${pin}\nV_VERSION=0.5.2\n'
}

fn fake_gh(log string) ! {
	args := os.args[1..]
	mut receipt := os.open_append(log)!
	defer { receipt.close() }
	match true {
		args == list_args {
			receipt.writeln('list')!
			match os.getenv('VLANG_PROPOSAL_MODE') {
				'existing' { println('[{"number":42}]') }
				'error' { return error('Simulated GitHub lookup failure') }
				else { println('[]') }
			}
		}
		args.len == create_args.len + 1 && args[..create_args.len] == create_args {
			assert os.read_file(args.last())!.contains(new_pin)
			receipt.writeln('create')!
			println('https://example.invalid/pull/42')
		}
		args == workflow_args {
			receipt.writeln('workflow')!
		}
		else {
			return error('Unexpected gh arguments: ${args}')
		}
	}
}

fn run_proposal(root string, checkout string, revision string, mode string, success bool, calls []string) !string {
	log := os.join_path(root, 'gh.log')
	os.write_file(log, '')!
	mut env := os.environ()
	env['PATH'] = os.join_path(root, 'bin') + ':' + os.getenv('PATH')
	env['VLANG_PROPOSAL_LOG'] = log
	env['VLANG_PROPOSAL_MODE'] = mode
	output := capture(os.join_path(root, 'propose'), [revision, base], success,
		work_folder: checkout
		environment: env
	)!
	assert os.read_lines(log)! == calls
	return output
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'kakoune-proposal-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	remote := os.join_path(root, 'remote.git')
	seed := os.join_path(root, 'seed')
	checkout := os.join_path(root, 'checkout')
	retry := os.join_path(root, 'retry')
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	os.symlink(os.executable(), os.join_path(bin, 'gh'))!
	capture('v', ['-skip-running', '-o', os.join_path(root, 'propose'),
		os.join_path(@DIR, 'propose-kakoune-update.vsh')], true)!
	capture('git', ['init', '-q', '--bare', '--initial-branch=${base}', remote], true)!
	capture('git', ['init', '-q', '--initial-branch=${base}', seed], true)!
	os.mkdir(os.join_path(seed, 'tests'))!
	os.write_file(os.join_path(seed, pin_path), release_env(old_pin))!
	capture('git', ['add', pin_path], true, work_folder: seed)!
	capture('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit',
		'-qm', 'Add release fixture'], true, work_folder: seed)!
	capture('git', ['push', remote, base], true, work_folder: seed)!
	capture('git', ['clone', '-q', remote, checkout], true)!

	assert run_proposal(root, checkout, old_pin, '', true, [])!.contains('already current')
	run_proposal(root, checkout, 'bad-pin', '', false, [])!
	run_proposal(root, checkout, new_pin, 'error', false, ['list'])!
	assert run_proposal(root, checkout, new_pin, 'existing', true, ['list'])!.contains('already exists')
	assert capture('git', ['branch', '--format=%(refname:short)'], true, work_folder: remote)!.trim_space() == base
	assert capture('git', ['status', '--porcelain'], true, work_folder: checkout)! == ''

	run_proposal(root, checkout, new_pin, '', true, ['list', 'list', 'create', 'workflow'])!
	assert capture('git', ['show', '${proposal_branch}:${pin_path}'], true, work_folder: remote)! == release_env(new_pin)
	assert capture('git', ['diff-tree', '--no-commit-id', '--name-only', '-r', proposal_branch],
		true, work_folder: remote)!.trim_space() == pin_path
	tip := capture('git', ['rev-parse', proposal_branch], true, work_folder: remote)!

	// A retry can open a proposal without recreating or pushing the prior branch.
	capture('git', ['clone', '-q', remote, retry], true)!
	run_proposal(root, retry, new_pin, '', true, ['list', 'list', 'create', 'workflow'])!
	assert capture('git', ['rev-parse', proposal_branch], true, work_folder: remote)! == tip
	assert capture('git', ['status', '--porcelain', '--branch'], true, work_folder: retry)!.trim_space() == '## master...origin/master'

	// An existing ref with the wrong pin should never reach PR creation.
	capture('git', ['update-ref', 'refs/heads/${proposal_branch}', base], true, work_folder: remote)!
	run_proposal(root, retry, new_pin, '', false, ['list'])!
	println('Kakoune proposal workflow checks passed')
}

if log := os.getenv_opt('VLANG_PROPOSAL_LOG') {
	fake_gh(log) or {
		eprintln(err)
		exit(1)
	}
} else {
	check() or {
		eprintln(err)
		exit(1)
	}
}
