// Resolve Git history for a file without involving the working tree in the view.
module main

import managedfiles { git_at }
import os

const recent_commits = '30'

struct HistoryFile {
	repo string
	path string
}

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn location(file string) !HistoryFile {
	if !os.is_file(file) {
		return error('Open a saved V file before browsing history')
	}
	resolved := os.real_path(file)
	repo := git_at(os.dir(resolved), ['rev-parse', '--show-toplevel']) or {
		return error('The current file is not in a Git repository')
	}
	if !resolved.starts_with(repo + '/') {
		return error('The current file is outside the Git repository')
	}
	return HistoryFile{
		repo: repo
		path: resolved[repo.len + 1..]
	}
}

fn (file HistoryFile) prepare(ref string) ! {
	if ref == '' || ref.starts_with('-') {
		return error('Pass a branch, tag, or commit name')
	}
	commit := git_at(file.repo, ['rev-parse', '--verify', '--end-of-options', ref + '^{commit}']) or {
		return error('Unknown Git revision')
	}
	git_at(file.repo, ['cat-file', '-e', '${commit}:${file.path}']) or {
		return error('This file does not exist at that revision')
	}
	short := git_at(file.repo, ['rev-parse', '--short=12', commit])!
	println('set-option window v_history_repo ${quote(file.repo)}')
	println('set-option window v_history_commit ${quote(commit)}')
	println('set-option window v_history_path ${quote(file.path)}')
	println('set-option window v_history_buffer ${quote('*v-history:${short}:${file.path}*')}')
}

fn (file HistoryFile) menu() {
	log := git_at(file.repo, ['--literal-pathspecs', 'log', '-n', recent_commits, '--format=%h %s',
		'HEAD', '--', file.path]) or { '' }
	mut commands := ["menu 'HEAD  current commit' 'v-history-file HEAD'"]
	for row in log.split_into_lines() {
		hash := row.all_before(' ')
		subject := row.all_after(' ').trim_space()
		commands << quote('${hash}  ${subject}')
		commands << quote('v-history-file ${hash}')
	}
	println(commands.join(' '))
}

fn run(args []string) ! {
	operation := args[0] or { '' }
	match operation {
		'prepare' {
			if args.len == 3 {
				location(args[1])!.prepare(args[2])!
				return
			}
		}
		'menu' {
			if args.len == 2 {
				location(args[1])!.menu()
				return
			}
		}
		'show' {
			if args.len == 4 {
				// Stream the blob without trimming its trailing newlines.
				return os.execvp('git', ['-C', args[1], 'show', '--end-of-options',
					'${args[2]}:${args[3]}'])
			}
		}
		else {}
	}

	return error('Expected prepare FILE REVISION, menu FILE, or show REPO COMMIT PATH')
}

fn main() {
	args := os.args[1..]
	run(args) or {
		if args.len > 0 && args[0] == 'show' {
			eprintln(err.msg())
		} else {
			println('fail ${quote(err.msg())}')
		}
		exit(1)
	}
}
