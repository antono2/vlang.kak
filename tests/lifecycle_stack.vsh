// Exercise recovery, rollback, and repair with copies of the pinned tool releases.
import os
import rand
import releasetest { capture }
import time

const tools = ['vlang-kakoune', 'vlang-kak-lsp', 'vlang-vls']
const activation_timeout = 2 * time.minute
const before_activation = '# All builds succeeded. Switch the prepared versions and generate launchers.'
const personal_edit = '# edited after interruption\n'
const kakrc_edit = '# kakrc edited after interruption\n'

enum Interruption {
	before
	partial
}

struct Stack {
	root             string
	repo             string
	prefix           string
	interrupted_repo string
	pins             releasetest.Pins
}

fn require(condition bool, detail string) ! {
	if !condition {
		return error(detail)
	}
}

fn copy_tree(source string, target string) ! {
	os.mkdir_all(os.dir(target))!
	// The recovery copy must preserve internal links and executable modes.
	capture('cp', ['-a', '--', source, target], true)!
}

fn (stack Stack) script(name string, extra []string, success bool) !string {
	mut args := ['--prefix', stack.prefix]
	args << extra
	return capture(os.join_path(stack.repo, 'scripts', name + '.sh'), args, success)
}

fn (stack Stack) setup(extra []string, success bool) ! {
	mut args := stack.pins.setup_args(stack.prefix)
	args << extra
	capture(os.join_path(stack.repo, 'scripts/setup.sh'), args, success)!
}

fn (stack Stack) link(tool string) string {
	return os.join_path(stack.prefix, 'opt', tool, 'current')
}

fn (stack Stack) links() !map[string]string {
	mut links := map[string]string{}
	for tool in tools {
		links[tool] = os.readlink(stack.link(tool))!
	}
	return links
}

fn (stack Stack) prepare(source string) ! {
	for tool in tools {
		current := os.real_path(os.join_path(source, 'opt', tool, 'current'))
		copy_tree(current, os.join_path(stack.prefix, 'opt', tool, 'releases',
			os.file_name(current)))!
	}
	os.setenv('XDG_CONFIG_HOME', os.join_path(stack.root, 'config'), true)
	os.setenv('XDG_CACHE_HOME', os.join_path(stack.root, 'cache'), true)
	os.setenv('VLANG_KAK_PREFIX', stack.prefix, true)
	os.setenv('VLANG_KAK_SKIP_PULL', '1', true)
	os.unsetenv('VLANG_KAK_CONFIG_HOME')
	stack.setup([], true)!
	// Distinct paths make partial activation observable even with identical builds.
	for tool in tools {
		link := stack.link(tool)
		previous := os.join_path(os.dir(link), 'releases/cached-previous')
		copy_tree(os.real_path(link), previous)!
		os.rm(link)!
		os.symlink(previous, link)!
	}
}

fn (stack Stack) git(extra []string) !string {
	mut args := ['-C', stack.interrupted_repo, '-c', 'user.name=Recovery Test', '-c',
		'user.email=recovery@example.invalid', '-c', 'commit.gpgsign=false']
	args << extra
	return capture('git', args, true)!.trim_space()
}

fn (stack Stack) prepare_interrupted_source() !string {
	releasetest.copy_source(stack.repo, stack.interrupted_repo)!
	// Recovery must keep running across checkout of an older rollback command.
	rollback := capture('git', ['-C', stack.repo, 'show', 'v1.2.0:scripts/rollback.sh'], true)!
	os.write_file(os.join_path(stack.interrupted_repo, 'scripts/rollback.sh'), rollback)!
	stack.git(['init', '-q'])!
	stack.git(['add', '.'])!
	stack.git(['commit', '-qm', 'previous release'])!
	return stack.git(['rev-parse', 'HEAD'])
}

fn (stack Stack) interrupt(phase Interruption, old_revision string, original_impl string) ! {
	marker := os.join_path(stack.root, 'activation-barrier')
	if os.exists(marker) {
		os.rm(marker)!
	}
	// Block only inside the test checkout after recording the precise boundary.
	barrier := '\n    touch ${os.quoted_path(marker)}\n    while :; do sleep 1; done\n'
	require(original_impl.count(before_activation) == 1,
		'Cannot instrument the pre-activation boundary')!
	os.write_file(os.join_path(stack.interrupted_repo, 'scripts/setup-impl.sh'), if phase == .before {
		original_impl.replace_once(before_activation, barrier + before_activation)
	} else {
		original_impl
	})!
	activation := os.read_file(os.join_path(stack.repo, 'scripts/setup-activation.vsh'))!
	os.write_file(os.join_path(stack.interrupted_repo, 'scripts/setup-activation.vsh'), if phase == .partial {
		releasetest.instrument_tool_activation(activation, marker)!
	} else {
		activation
	})!
	os.write_file(os.join_path(stack.interrupted_repo, 'scripts/rollback.sh'), os.read_file(os.join_path(stack.repo,
		'scripts/rollback.sh'))!)!
	stack.git(['add', '.'])!
	stack.git(['commit', '-qm', 'candidate ${phase}'])!

	mut env := os.environ()
	env['VLANG_KAK_PREVIOUS_PLUGIN_REVISION'] = old_revision
	mut args := stack.pins.setup_args(stack.prefix)
	args << '--integrate'
	releasetest.interrupt_at_marker(os.join_path(stack.interrupted_repo, 'scripts/update.sh'),
		args, marker,
		environment: env
		timeout:     activation_timeout
	) or { return error('${phase} activation: ${err}') }
}

fn (stack Stack) reject_snapshots(state string, pending string) ! {
	foreign := os.join_path(stack.root, 'pending.foreign')
	os.mkdir_all(foreign)!
	stack.script('rollback', ['--recover', foreign], false)!
	alias := os.join_path(state, 'pending.alias')
	os.symlink(pending, alias)!
	stack.script('rollback', ['--recover', alias], false)!
	require(os.is_link(alias), 'Recovery changed the rejected snapshot alias')!
	os.rm(alias)!
	incomplete := os.join_path(state, 'pending.incomplete')
	copy_tree(pending, incomplete)!
	os.rm(os.join_path(incomplete, 'ready'))!
	stack.script('rollback', ['--recover', incomplete], false)!
	require(os.is_dir(incomplete), 'Recovery changed the rejected incomplete snapshot')!
	os.rmdir_all(incomplete)!
}

fn (stack Stack) recover(phase Interruption, old_revision string, before map[string]string,
	launcher []u8, personal string, kakrc string, kakrc_target string) ! {
	after := stack.links()!
	if phase == .before {
		require(after == before, 'Tools changed before the activation boundary')!
	} else {
		require(after['vlang-kakoune'] != before['vlang-kakoune']
			&& after['vlang-kak-lsp'] == before['vlang-kak-lsp']
			&& after['vlang-vls'] == before['vlang-vls'],
			'Partial activation must switch only Kakoune')!
	}
	state := os.join_path(stack.prefix, 'opt/vlang-state')
	matches := os.ls(state)!.filter(it.starts_with('pending.'))
	require(matches.len == 1, 'Expected one pending transaction after ${phase} interruption')!
	pending := os.join_path(state, matches[0])
	require(os.is_file(os.join_path(pending, 'ready'))
		&& os.read_file(os.join_path(pending, 'plugin-revision'))!.trim_space() == old_revision,
		'Pending transaction is incomplete or cites the wrong plugin revision')!
	owner := stack.script('lock', [], false)!
	require(owner.contains('stale setup'), 'Interrupted setup did not leave a stale lock\n${owner}')!
	os.write_file(personal, os.read_file(personal)! + personal_edit)!
	os.write_file(kakrc_target, os.read_file(kakrc_target)! + kakrc_edit)!
	stack.script('rollback', ['--recover', pending], false)!
	stack.script('lock', ['--clear-stale'], true)!
	stack.reject_snapshots(state, pending)!
	capture(os.join_path(stack.interrupted_repo, 'scripts/rollback.sh'), ['--prefix', stack.prefix,
		'--recover', pending], true)!
	require(stack.git(['rev-parse', 'HEAD'])! == old_revision,
		'Recovery did not check out the previous plugin revision')!
	stack.require_active(before, launcher)!
	require(os.read_file(personal)!.contains(personal_edit) && os.readlink(kakrc)! == kakrc_target
		&& os.read_file(kakrc_target)!.contains(kakrc_edit),
		'Recovery lost personal edits or the kakrc symlink')!
	require(!os.exists(pending), 'Recovery retained the completed pending snapshot')!
}

fn (stack Stack) require_active(links map[string]string, launcher []u8) ! {
	require(stack.links()! == links
		&& os.read_bytes(os.join_path(stack.prefix, 'bin/kak-v'))! == launcher,
		'Active tool links or launcher bytes changed')!
}

fn (stack Stack) exercise() ! {
	links := stack.links()!
	launcher := os.read_bytes(os.join_path(stack.prefix, 'bin/kak-v'))!
	old_revision := stack.prepare_interrupted_source()!
	implementation := os.read_file(os.join_path(stack.interrupted_repo, 'scripts/setup-impl.sh'))!
	config := os.join_path(stack.root, 'config/kak')
	os.mkdir_all(config)!
	personal := os.join_path(config, 'vlang-user.kak')
	os.write_file(personal, '# personal settings before interruption\n')!
	kakrc_target := os.join_path(stack.root, 'personal-kakrc')
	os.write_file(kakrc_target, '# original personal kakrc\n')!
	kakrc := os.join_path(config, 'kakrc')
	os.symlink(kakrc_target, kakrc)!
	for phase in [Interruption.before, .partial] {
		stack.interrupt(phase, old_revision, implementation)!
		stack.recover(phase, old_revision, links, launcher, personal, kakrc, kakrc_target)!
	}
	println('ok - SIGKILL before/within update activation, stale lock recovery and preservation of personal edits')

	stack.setup(['--vls-ref', 'vlang-kak-test-invalid-ref'], false)!
	stack.require_active(links, launcher)!
	ide_config := os.join_path(stack.prefix, 'opt/vlang-kakoune/ide-config/kak')
	generated := os.join_path(ide_config, 'kakrc')
	stack.setup(['--pane-mode', 'off'], true)!
	require(os.read_file(generated)!.contains('v_pane_mode off'), 'Setup did not apply pane mode')!
	stack.script('rollback', [], true)!
	require(os.read_file(generated)!.contains('v_pane_mode auto'),
		'Rollback did not restore pane mode')!
	plugin := os.join_path(ide_config, 'autoload/vlang.kak')
	os.rm(plugin)!
	capture(os.join_path(stack.repo, 'scripts/health.sh'), ['--repair'], true)!
	require(os.real_path(plugin) == os.join_path(stack.repo, 'rc/vlang.kak'),
		'Repair did not restore the owned autoload link')!
	release := os.join_path(stack.prefix, 'opt/vlang-vls/releases', stack.pins.vls_ref)
	added := os.join_path(release, 'my-notes.txt')
	changed := os.join_path(release, '.vlang-commit')
	os.write_file(added, 'keep me')!
	os.write_file(changed, 'edited')!
	stack.setup([], true)!
	manifest := os.read_file(os.join_path(stack.prefix, 'opt/vlang-state/manifest.tsv'))!
	require(!manifest.contains(added), 'Setup adopted an unowned release file')!
	stack.script('uninstall', ['--apply'], true)!
	require(os.read_file(added)! == 'keep me' && os.read_file(changed)! == 'edited',
		'Uninstallation changed an unowned or modified release file')!
	println('ok - complete-stack failed update, rollback, missing-link repair and release ownership preservation')
}

fn run(source string) ! {
	root := os.real_path(os.join_path(os.temp_dir(), 'vlang-stack-' + rand.uuid_v4()))
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	stack := Stack{
		root:             root
		repo:             os.dir(@DIR)
		prefix:           os.join_path(root, 'prefix')
		interrupted_repo: os.join_path(root, 'interrupted-source')
		pins:             releasetest.read_pins(os.join_path(@DIR, 'release.env'))!
	}
	stack.prepare(os.real_path(source))!
	stack.exercise()!
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/lifecycle_stack.vsh TOOLS_PREFIX')
	exit(2)
}
run(os.args[1]) or {
	eprintln('not ok - complete-stack lifecycle: ${err}')
	exit(1)
}
