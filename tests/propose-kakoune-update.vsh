// Propose the Kakoune revision that passed the full release gate.
import json2
import os
import rand
import releasetest { capture, capture_result }

const pin_path = 'tests/release.env'
const key = 'KAKOUNE_VERSION='
// git ls-remote --exit-code uses 2 when no refs match.
const missing_remote_ref = 2
const git_name = 'user.name=github-actions[bot]'
const git_email = 'user.email=41898282+github-actions[bot]@users.noreply.github.com'
const usage = 'Usage: v run tests/propose-kakoune-update.vsh VERIFIED_SHA DEFAULT_BRANCH'

struct PullRequest {
	number int
}

fn pin_line(lines []string) !int {
	matches := lines.filter(it.starts_with(key))
	if matches.len != 1 {
		return error('Expected one Kakoune pin in ${pin_path}')
	}
	return lines.index(matches[0])
}

fn previous_proposal(branch string) !bool {
	// Include closed and merged proposals so a prior decision is respected.
	raw :=
		capture('gh', ['pr', 'list', '--head', branch, '--state', 'all', '--json', 'number'], true)!
	return json2.decode[[]PullRequest](raw)!.len > 0
}

fn remote_branch(branch string, pin string) !bool {
	ref := 'refs/heads/${branch}'
	result := capture_result('git', ['ls-remote', '--exit-code', 'origin', ref])!
	if result.code == missing_remote_ref {
		return false
	}
	if result.code != 0 {
		return error('Could not read ${ref} from origin: ${result.stderr}')
	}
	// A retry may find a branch already pushed by a previous run.
	capture('git', ['fetch', '--no-tags', '--depth=1', 'origin', ref], true)!
	text := capture('git', ['show', 'FETCH_HEAD:${pin_path}'], true)!
	lines := text.split_into_lines()
	if lines[pin_line(lines)!] != pin {
		return error('The existing branch ${branch} contains a different Kakoune pin')
	}
	return true
}

fn propose(revision string, base string) ! {
	if revision.len != 40 || !revision.bytes().all((it >= `0` && it <= `9`)
		|| (it >= `a` && it <= `f`)) {
		return error('Expected the verified 40-character Kakoune commit SHA')
	}
	if base == '' {
		return error('Missing GitHub default branch')
	}
	mut lines := os.read_lines(pin_path)!
	index := pin_line(lines)!
	pin := key + revision
	if lines[index] == pin {
		println('The verified Kakoune pin is already current')
		return
	}
	branch := 'automation/kakoune-${revision}'
	if previous_proposal(branch)! {
		println('A proposal already exists for ${revision}')
		return
	}
	if !remote_branch(branch, pin)! {
		capture('git', ['switch', '-c', branch], true)!
		lines[index] = pin
		os.write_file(pin_path, lines.join('\n') + '\n')!
		capture('git', ['diff', '--check', '--', pin_path], true)!
		capture('git', ['-c', git_name, '-c', git_email, 'commit', '-m',
			'Test IDE against Kakoune ${revision}', '--', pin_path], true)!
		capture('git', ['push', 'origin', branch], true)!
	}
	// Check again in case another run opened the proposal while this job pushed.
	if previous_proposal(branch)! {
		println('A proposal already exists for ${revision}')
		return
	}
	body := os.join_path(os.temp_dir(), 'kakoune-update-' + rand.uuid_v4() + '.md')
	defer { os.rm(body) or {} }
	body_text := [
		'Weekly Kakoune master update to `${revision}`.',
		'',
		'The clean install, automated IDE acceptance pass and managed update checks passed.',
		'Review the uploaded logs before advancing the Kakoune pin.',
		'',
	].join('\n')
	os.write_file(body, body_text)!
	print(capture('gh', ['pr', 'create', '--base', base, '--head', branch, '--title',
		'Update verified Kakoune master revision', '--body-file', body], true)!)
	// Default workflow inputs verify the proposed ref without proposing another update.
	capture('gh', ['workflow', 'run', 'test.yml', '--ref', branch], true)!
}

if os.args[1..] in [['--help'], ['-h']] {
	println(usage)
} else if os.args.len != 3 {
	eprintln(usage)
	exit(2)
} else {
	propose(os.args[1], os.args[2]) or {
		eprintln(err)
		exit(1)
	}
}
