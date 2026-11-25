"""Trusted staging launcher for compiled Core Data models (not source generation)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


INPUT_MARKER = "--drive-native-model-inputs"


def run(arguments, *, compiler="momc"):
    """Stage declared model files, run the selected tool closed, publish on success."""
    suffixes = {"momc": (".xcdatamodeld", ".xcdatamodel"), "mapc": (".xcmappingmodel",)}
    if compiler not in suffixes:
        raise ValueError("unsupported model compiler")
    if arguments.count(INPUT_MARKER) != 1:
        raise ValueError("missing or duplicate declared model input list")
    marker = arguments.index(INPUT_MARKER)
    toolargs, sources = arguments[:marker], arguments[marker + 1:]
    if len(toolargs) < 2 or not sources:
        raise ValueError("missing model arguments or inputs")
    model, output = [Path(arg).absolute() for arg in toolargs[-2:]]
    if model.suffix not in suffixes[compiler]:
        raise ValueError("unsupported model input")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("refusing stale model output")
    developer = Path(os.environ["DEVELOPER_DIR"]).resolve()
    tool = developer / "usr/bin" / compiler
    helper = developer / "Library/Xcode/Agents/cdtool"
    profile = Path(__file__).resolve().parents[1] / "native_build/asset_sandbox.sb"
    if not all(path.is_file() for path in (tool, helper, profile)):
        raise ValueError("missing declared profile or pinned model compiler/helper")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-model-", dir=output.parent) as temporary:
        root = Path(temporary).resolve()
        inputs, state = root / "inputs", root / "state"
        staged = inputs / model.name
        staged.mkdir(parents=True)
        state.mkdir()
        for source in sources:
            path = Path(source)
            if not path.is_relative_to(model):
                raise ValueError("declared input outside model")
            relative = path.relative_to(model)
            if ".." in relative.parts or not path.is_file():
                raise ValueError("invalid declared model input")
            destination = staged / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            # Materialize declared symlinks as bytes, never sandbox escape links.
            shutil.copyfile(path, destination)
        home, tmp = state / "home", state / "tmp"
        home.mkdir()
        tmp.mkdir()
        compiled = state / output.name
        environment = {
            "PATH": "/usr/bin:/bin", "DEVELOPER_DIR": str(developer),
            "CDTOOL_PATH": str(helper), "HOME": str(home),
            "CFFIXED_USER_HOME": str(home), "TMPDIR": str(tmp),
        }
        command = ["/usr/bin/sandbox-exec", "-f", str(profile)]
        for key, value in {
            "XCODE": developer.parent, "XCODE_BUNDLE": developer.parent.parent,
            "CATALOG": inputs, "STATE": state, "TOOL": tool,
        }.items():
            command.extend(["-D", f"{key}={value}"])
        command += [str(tool)] + toolargs[:-2] + [str(staged), str(compiled)]
        # DVT helper launch fails if it inherits a cwd outside the read grants.
        status = subprocess.run(command, env=environment, cwd=state, check=False).returncode
        if status:
            return status
        if compiled.is_dir():
            if not any(compiled.iterdir()):
                raise ValueError("compiler produced an empty model")
            # Bazel precreates empty tree-artifact directories before execution.
            shutil.copytree(compiled, output, dirs_exist_ok=True)
        elif compiled.is_file():
            shutil.copyfile(compiled, output)
        else:
            raise ValueError("compiler did not produce its declared model")
    return 0
