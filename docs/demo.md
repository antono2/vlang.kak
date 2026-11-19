# IDE demonstration

The README animation contains six screens captured from a real Kakoune client:
the source Space menu, a definition jump, documentation with a signature, the
project explorer, a passing test at the cursor and debugger variables with
their direct Space commands. It uses a small V project and the single-client
interface. Pane workflows are covered separately by automated real-client tests.

The V recorder drives Kakoune in a private tmux session and uses the managed
VLS and GDB to capture the six screens. ImageMagick renders the terminal
captures and encodes the GIF. The recorder uses a temporary project, settings,
and cache.

To regenerate the demo, use a managed installation, a compatible V compiler,
tmux, GDB with DAP, ImageMagick, and DejaVu Sans Mono. On Ubuntu, the rendering
packages are `imagemagick` and `fonts-dejavu-core`.

```sh
v run tests/record_demo.vsh /absolute/managed-prefix docs/assets/ide.gif
```

Add `--frames /absolute/artifact-directory` to save the six PNG frames for
inspection. Each GIF frame is displayed for three seconds. Failed recordings
keep their terminal captures and last screen at the temporary path printed
by the recorder. Successful recordings clean up that directory.

The managed-editor CI job records the demo and includes the GIF and PNGs in
its `release-verification` artifact.
