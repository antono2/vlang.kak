// Compare installed and published releases and record successful checks.
import os
import semver
import time

const release_remote = 'https://github.com/antono2/vlang.kak.git'
const tag_prefix = 'refs/tags/'
const check_interval = 7 * 24 * time.hour
const remote_git = ['git', '-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=10', 'ls-remote']

struct Release {
	tag     string
	version semver.Version
	object  string
}

fn stable_version(tag string) !semver.Version {
	if !tag.starts_with('v') {
		return error('Expected a version tag')
	}
	parts := tag[1..].split('.')
	if parts.len != 3 || parts.any(it == '' || !it.bytes().all(it >= `0` && it <= `9`)) {
		return error('Expected a stable version tag')
	}
	return semver.from(tag[1..])
}

fn git(prefix []string, suffix []string) !string {
	mut args := prefix.clone()
	args << suffix
	result := os.execute(args.map(os.quoted_path(it)).join(' ') + ' 2>&1')
	if result.exit_code != 0 {
		return error('Git release check failed: ${result.output.trim_space()}')
	}
	return result.output.trim_space()
}

fn latest_release() !Release {
	listing := git(remote_git, ['--tags', '--refs', release_remote, 'v[0-9]*'])!
	mut latest := Release{}
	for line in listing.split_into_lines() {
		object, ref := line.split_once('\t') or { continue }
		if !ref.starts_with(tag_prefix) {
			continue
		}
		tag := ref[tag_prefix.len..]
		version := stable_version(tag) or { continue }
		if latest.tag == '' || latest.version < version {
			latest = Release{tag, version, object}
		}
	}
	if latest.tag == '' {
		return error('No stable release tags were published')
	}
	return latest
}

fn release_commit(release Release) !string {
	// Annotated tags need peeling. Lightweight tags already point at a commit.
	ref := '${tag_prefix}${release.tag}^{}'
	peeled := git(remote_git, [release_remote, ref])!
	if peeled == '' {
		return release.object
	}
	object, name := peeled.split_once('\t') or { return error('Invalid peeled release reference') }
	if name != ref || object == '' {
		return error('Unexpected peeled release reference')
	}
	return object
}

fn update_status(release Release) !string {
	repo := ['git', '-C', os.dir(@DIR)]
	installed := git(repo, ['describe', '--tags', '--always']) or { 'unknown' }
	head := git(repo, ['rev-parse', 'HEAD']) or { '' }
	target := release_commit(release)!
	if head != '' && head == target {
		return 'Up to date: ${release.tag}'
	}
	// git describe can include commits after a tag. Compare the base version
	// so a checkout already at or beyond that release does not get a prompt.
	base_tag := installed.all_before('-').all_before('+')
	installed_version := stable_version(base_tag) or {
		return available_status(release.tag, installed)
	}
	if installed_version < release.version {
		return available_status(release.tag, installed)
	}
	return 'Installed: ${installed}. Latest release: ${release.tag}.'
}

fn available_status(tag string, installed string) string {
	return 'Release available: ${tag} (installed: ${installed}). Use :v-update-release to install it.'
}

fn check(state string, background bool) ! {
	stamp := os.join_path(state, 'update-checked')
	if background && os.is_file(stamp)
		&& time.utc().unix() - os.file_last_mod_unix(stamp) < i64(check_interval / time.second) {
		return
	}
	status := update_status(latest_release()!)!
	os.write_file(os.join_path(state, 'update-status'), status + '\n')!
	os.write_file(stamp, time.utc().format_rfc3339() + '\n')!
	println(status)
}

// The launcher supplies the state directory and holds its lock.
if os.args.len !in [2, 3] || (os.args.len == 3 && os.args[2] != '--background') {
	eprintln('Usage: check-updates.sh [--background]')
	exit(2)
}
check(os.args[1], os.args.len == 3) or {
	eprintln(err)
	exit(1)
}
