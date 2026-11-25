"""Run Apple's asset compiler with staged declared inputs and native isolation.

The Python launcher is trusted setup code, not itself inside Seatbelt. It may
read only the file list supplied by the rule for staging. This is opt-in while
native runtime identity and full resource-graph compatibility are verified.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


INPUT_MARKER = "--drive-native-inputs"


def stage_inputs(arguments, sources, root):
    """Copy declared files into separate catalog trees and rewrite catalog args."""
    catalogs = [Path(arg) for arg in arguments
                if arg.endswith((".xcassets", ".xcstickers", ".icon"))]
    if not catalogs:
        raise ValueError("asset action has no catalog inputs")
    staged = {}
    for index, catalog in enumerate(catalogs):
        target = root / str(index) / catalog.name
        target.mkdir(parents=True)
        staged[str(catalog)] = target
    for source in sources:
        path = Path(source)
        owners = [catalog for catalog in catalogs if path.is_relative_to(catalog)]
        if len(owners) != 1:
            raise ValueError("declared asset must belong to exactly one catalog: " + source)
        catalog = owners[0]
        relative = path.relative_to(catalog)
        if ".." in relative.parts or not path.is_file():
            raise ValueError("invalid declared asset: " + source)
        destination = staged[str(catalog)] / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
    return [str(staged[arg]) if arg in staged else arg for arg in arguments]


def run(arguments):
    """Return compiler status. Never fall back to an unconfined invocation."""
    if arguments.count(INPUT_MARKER) != 1:
        raise ValueError("missing or duplicate declared asset input list")
    marker = arguments.index(INPUT_MARKER)
    toolargs, sources = arguments[:marker], arguments[marker + 1:]
    output_index = toolargs.index("--compile") + 1
    output = Path(toolargs[output_index]).absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    developer = Path(os.environ["DEVELOPER_DIR"]).resolve()
    tool = developer / "usr/bin/actool"
    profile = Path(__file__).resolve().parents[1] / "native_build/asset_sandbox.sb"
    if not profile.is_file() or not tool.is_file():
        raise ValueError("missing declared sandbox profile or pinned compiler")
    with tempfile.TemporaryDirectory(prefix=".native-asset-", dir=output.parent) as temporary:
        root = Path(temporary).resolve()
        inputs, state = root / "inputs", root / "state"
        inputs.mkdir()
        state.mkdir()
        home, tmp, compiled = state / "home", state / "tmp", state / "compiled"
        for directory in (home, tmp, compiled):
            directory.mkdir()
        rewritten = stage_inputs(toolargs, sources, inputs)
        rewritten[output_index] = str(compiled)
        plist_output = None
        if "--output-partial-info-plist" in rewritten:
            index = rewritten.index("--output-partial-info-plist") + 1
            plist_output = Path(rewritten[index]).absolute()
            rewritten[index] = str(state / "partial.plist")
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVELOPER_DIR": str(developer),
            "IBToolNeverDeque": "1",
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": str(tmp),
        }
        command = ["/usr/bin/sandbox-exec", "-f", str(profile)]
        parameters = {
            "XCODE": developer.parent, "XCODE_BUNDLE": developer.parent.parent,
            "CATALOG": inputs, "STATE": state, "TOOL": tool,
        }
        for key, value in parameters.items():
            command.extend(["-D", key + "=" + str(value)])
        command += [str(tool)] + rewritten + [
            "--assetruntime-environment", "HOME=" + str(home),
            "--assetruntime-environment", "TMPDIR=" + str(tmp),
        ]
        # Keep all diagnostics visible, including denied optional services.
        status = subprocess.run(command, env=environment, check=False).returncode
        if status:
            return status
        # Empty catalogs (including the app's test-host placeholders) legitimately
        # produce no CAR. Match the upstream contract: successful compilation and
        # the declared output directory/plist, not a mandatory Assets.car file.
        if output.exists() and any(output.iterdir()):
            raise ValueError("refusing to merge with stale asset output")
        shutil.copytree(compiled, output, dirs_exist_ok=True)
        if plist_output is not None:
            plist_output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(state / "partial.plist", plist_output)
    return 0
