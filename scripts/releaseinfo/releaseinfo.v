// Read published stable release tags and invoke Git with literal arguments.
module releaseinfo

import os
import semver
import time

pub const release_remote = 'https://github.com/antono2/vlang.kak.git'
const tag_prefix = 'refs/tags/'
const poll_interval = 10 * time.millisecond

pub struct Release {
pub:
	tag     string
	version semver.Version
	object  string
}

pub struct GitResult {
pub:
	code        int
	output      string
	diagnostics string
}

pub fn invoke_git(args []string) GitResult {
	mut child := os.new_process('git')
	defer { child.close() }
	child.set_args(args)
	child.set_redirect_stdio()
	child.run()
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	mut output := ''
	mut diagnostics := ''
	for child.is_alive() {
		output += child.stdout_read()
		diagnostics += child.stderr_read()
		time.sleep(poll_interval)
	}
	output += child.stdout_slurp()
	diagnostics += child.stderr_slurp()
	child.wait()
	return GitResult{
		code:        child.code
		output:      output.trim_right('\n')
		diagnostics: diagnostics.trim_space()
	}
}

pub fn git(args []string) !string {
	result := invoke_git(args)
	if result.code != 0 {
		return error('Git ${args.join(' ')} failed: ${result.diagnostics}')
	}
	return result.output
}

pub fn git_at(repo string, args []string) !string {
	mut command := ['-C', repo]
	command << args
	return git(command)
}

fn remote_git(suffix []string) !string {
	mut args := ['-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=10', 'ls-remote']
	args << suffix
	return git(args)
}

pub fn stable_version(tag string) !semver.Version {
	if !tag.starts_with('v') {
		return error('Expected a version tag')
	}
	parts := tag[1..].split('.')
	if parts.len != 3 || parts.any(it == '' || !it.bytes().all(it >= `0` && it <= `9`)) {
		return error('Expected a stable version tag')
	}
	return semver.from(tag[1..])
}

pub fn latest_release() !Release {
	listing := remote_git(['--tags', '--refs', release_remote, 'v[0-9]*'])!
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

pub fn release_commit(release Release) !string {
	// Annotated tags need peeling. Lightweight tags already point at a commit.
	ref := '${tag_prefix}${release.tag}^{}'
	peeled := remote_git([release_remote, ref])!
	if peeled == '' {
		return release.object
	}
	object, name := peeled.split_once('\t') or { return error('Invalid peeled release reference') }
	if name != ref || object == '' {
		return error('Unexpected peeled release reference')
	}
	return object
}
