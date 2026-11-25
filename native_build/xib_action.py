"""Trusted single-XIB staging followed by deny-by-default ibtool execution."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


INPUT_MARKER = "--drive-native-xib-input"


def run(arguments):
    if arguments.count(INPUT_MARKER) != 1:
        raise ValueError("missing or duplicate declared XIB input")
    marker = arguments.index(INPUT_MARKER)
    toolargs, sources = arguments[:marker], arguments[marker + 1:]
    if len(sources) != 1 or not toolargs or toolargs[-1] != sources[0]:
        raise ValueError("XIB invocation must match its one declared input")
    source = Path(sources[0])
    if source.suffix != ".xib" or not source.is_file():
        raise ValueError("invalid XIB input")
    if toolargs.count("--compile") != 1:
        raise ValueError("expected XIB compilation")
    index = toolargs.index("--compile") + 1
    output = Path(toolargs[index]).absolute()
    if output.exists():
        raise ValueError("refusing stale NIB output")
    developer = Path(os.environ["DEVELOPER_DIR"]).resolve()
    tool = developer / "usr/bin/ibtool"
    profile = Path(__file__).resolve().parents[1] / "native_build/asset_sandbox.sb"
    if not tool.is_file() or not profile.is_file():
        raise ValueError("missing pinned ibtool or declared profile")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-xib-", dir=output.parent) as temporary:
        root = Path(temporary).resolve()
        inputs, state = root / "inputs", root / "state"
        inputs.mkdir()
        state.mkdir()
        staged = inputs / source.name
        # Preserve Interface Builder's path-based localization semantics without
        # granting access to any undeclared neighboring strings or source files.
        if source.parent.suffix == ".lproj":
            staged = inputs / source.parent.name / source.name
            staged.parent.mkdir()
        shutil.copyfile(source, staged)
        home, tmp = state / "home", state / "tmp"
        home.mkdir()
        tmp.mkdir()
        compiled = state / output.name
        rewritten = list(toolargs)
        rewritten[index] = str(compiled)
        rewritten[-1] = str(staged)
        command = ["/usr/bin/sandbox-exec", "-f", str(profile)]
        for key, value in {
            "XCODE": developer.parent, "XCODE_BUNDLE": developer.parent.parent,
            "CATALOG": inputs, "STATE": state, "TOOL": tool,
        }.items():
            command.extend(["-D", f"{key}={value}"])
        environment = {
            "PATH": "/usr/bin:/bin", "DEVELOPER_DIR": str(developer),
            "IBToolNeverDeque": "1", "HOME": str(home),
            "CFFIXED_USER_HOME": str(home), "TMPDIR": str(tmp),
        }
        status = subprocess.run(command + [str(tool)] + rewritten,
                                env=environment, cwd=state, check=False).returncode
        if status:
            return status
        if compiled.is_dir() and any(compiled.iterdir()):
            shutil.copytree(compiled, output)
        elif compiled.is_file() and compiled.stat().st_size:
            shutil.copyfile(compiled, output)
        else:
            raise ValueError("compiler did not produce a nonempty NIB")
    return 0
