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
	capture(updater, [local], true)!
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
