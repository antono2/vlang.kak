// Resolve setup choices from explicit flags, existing kakrc and defaults.
import os
import setupconfig

fn invalid(message string) {
	eprintln(message)
	exit(2)
}

fn main() {
	if os.args.len != 8 {
		invalid('Usage: setup-defaults.vsh { --resolve-config PREFIX | SETTINGS_KAKRC PERSONAL_KAKRC } INTEGRATE EXPLORER LIVE_SEARCH PANE_MODE WINDOW_BACKEND')
	}
	mut settings_path := os.args[1]
	mut personal_path := os.args[2]
	mut output := []string{}
	if os.args[1] == '--resolve-config' {
		paths := setupconfig.resolve(os.args[2]) or {
			eprintln(err.msg())
			exit(if err.code() == 2 { 2 } else { 1 })
		}
		settings_path = paths.settings
		personal_path = paths.personal
		output << [paths.home, settings_path]
	}
	chosen := setupconfig.preferences(settings_path, personal_path, setupconfig.Preferences{
		integrate:      os.args[3]
		explorer:       os.args[4]
		live_search:    os.args[5]
		pane_mode:      os.args[6]
		window_backend: os.args[7]
	}) or {
		eprintln(err.msg())
		exit(if err.code() == 2 { 2 } else { 1 })
	}
	output << [chosen.integrate, chosen.explorer, chosen.live_search, chosen.pane_mode,
		chosen.window_backend]
	println(output.join('\n'))
}
