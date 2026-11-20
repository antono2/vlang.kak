// Exercise checkout refresh against a local repository without using a network.
import os
import rand
import releasetest { capture, execute }

fn git(repo string, arguments []string) !string {
	mut args := ['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.com']
	args << arguments
	return capture('git', args, true)!
}

fn commit(repo string, content string) !string {
	os.write_file(os.join_path(repo, 'sample.txt'), content)!
	git(repo, ['add', '--', 'sample.txt'])!
	git(repo, ['commit', '-q', '-m', content])!
	return git(repo, ['rev-parse', 'HEAD'])
}

fn check(root string) ! {
	scripts := os.join_path(os.dir(@DIR), 'scripts')
	updater := os.join_path(root, 'checkout-updater')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', updater,
		os.join_path(scripts, 'setup-repository.vsh')], true)!
	assert capture(updater, [root], true)!.contains('Keeping local vlang.kak checkout')

	upstream := os.join_path(root, 'upstream checkout')
	local := os.join_path(root, "user's checkout")
	os.mkdir(upstream)!
	git(upstream, ['init', '-q', '-b', 'main'])!
	first := commit(upstream, 'first')!
	capture('git', ['clone', '-q', upstream, local], true)!
	next := commit(upstream, 'next')!

	notes := os.join_path(local, 'personal-notes')
	os.write_file(notes, 'keep my changes')!
	assert capture(updater, [local], true)!.contains('Keeping local vlang.kak checkout')
	assert git(local, ['rev-parse', 'HEAD'])! == first
	assert os.read_file(notes)! == 'keep my changes'
	os.rm(notes)!

	preparer := os.join_path(root, 'prepare-installation')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', preparer,
		os.join_path(scripts, 'setup-paths.vsh')], true)!
	prefix := os.join_path(root, 'installation prefix')
	config := os.join_path(root, 'personal configuration')
	state := os.join_path(prefix, 'opt', 'vlang-state')
	vls := os.join_path(prefix, 'bin', 'vls')
	kakrc := os.join_path(config, 'kak', 'kakrc')
	os.mkdir_all(state)!
	os.mkdir_all(os.dir(kakrc))!
	os.write_file(os.join_path(state, 'manifest.tsv'), 'link\t/bin/true\t${vls}\n')!
	os.symlink(os.join_path(root, 'absent kakrc'), kakrc)!
	args := ['--prepare', prefix, local, config, 'true', 'true', 'true']
	mut env := os.environ()
	env['VLANG_KAK_SKIP_PULL'] = '0'
	refused := execute(preparer, args, false, environment: env)!
	assert refused.stderr.contains('Broken kakrc link:')
	assert !os.is_link(vls) && git(local, ['rev-parse', 'HEAD'])! == first
	os.rm(kakrc)!
	capture(preparer, args, true, environment: env)!
	assert os.readlink(vls)! == '/bin/true'
	assert git(local, ['rev-parse', 'HEAD'])! == next
	assert os.read_file(os.join_path(local, 'sample.txt'))! == 'next'

	our_commit := commit(local, 'our changes')!
	commit(upstream, 'upstream changes')!
	execute(updater, [local], false)!
	assert git(local, ['rev-parse', 'HEAD'])! == our_commit
	assert os.read_file(os.join_path(local, 'sample.txt'))! == 'our changes'
}

scratch := os.join_path(os.temp_dir(), 'vlang-setup-repository-' + rand.uuid_v4())
os.mkdir(scratch, mode: 0o700) or { panic(err) }
defer { os.rmdir_all(scratch) or {} }
check(scratch) or { panic(err) }
println('ok - setup refresh fast-forwards clean clones and preserves dirty or diverged checkouts')
