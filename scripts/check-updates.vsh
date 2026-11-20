// Compare installed and published releases and record successful checks.
import os
import releaseinfo { Release, git_at, latest_release, release_commit, stable_version }
import time

const check_interval = 7 * 24 * time.hour

fn update_status(release Release) !string {
	repo := os.dir(@DIR)
	installed := git_at(repo, ['describe', '--tags', '--always']) or { 'unknown' }
	head := git_at(repo, ['rev-parse', 'HEAD']) or { '' }
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
