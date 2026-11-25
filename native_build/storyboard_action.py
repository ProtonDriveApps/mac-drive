"""Trusted staging for storyboard compilation/linking, followed by native isolation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


MARKER = "--drive-native-storyboard"


def run(arguments):
    if arguments.count(MARKER) != 1:
        raise ValueError("missing or duplicate storyboard manifest")
    marker = arguments.index(MARKER)
    toolargs, manifest = arguments[:marker], arguments[marker + 1:]
    if len(manifest) < 3 or manifest[0] not in ("compile", "link"):
        raise ValueError("invalid storyboard manifest")
    mode, destination, *sources = manifest
    output = Path(destination).absolute()
    option = "--compilation-directory" if mode == "compile" else "--link"
    if toolargs.count(option) != 1 or toolargs[-len(sources):] != sources:
        raise ValueError("storyboard invocation differs from declared inputs")
    if mode == "compile" and (len(sources) != 1 or not sources[0].endswith(".storyboard")):
        raise ValueError("expected one storyboard source")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("refusing stale storyboard output")
    developer = Path(os.environ["DEVELOPER_DIR"]).resolve()
    tool = developer / "usr/bin/ibtool"
    profile = Path(__file__).resolve().parents[1] / "native_build/asset_sandbox.sb"
    if not tool.is_file() or not profile.is_file():
        raise ValueError("missing pinned ibtool or declared profile")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-storyboard-", dir=output.parent) as temporary:
        root = Path(temporary).resolve()
        inputs, state = root / "inputs", root / "state"
        inputs.mkdir()
        state.mkdir()
        staged = []
        for index, source in enumerate(sources):
            path = Path(source)
            target = inputs / str(index) / path.name
            # ibtool infers localizable-string encoding from the source's lproj
            # parent. It is semantic input even though sibling files are not.
            if mode == "compile" and path.parent.suffix == ".lproj":
                target = target.parent / path.parent.name / path.name
            target.parent.mkdir(parents=True)
            if mode == "compile":
                shutil.copyfile(path, target)
            else:
                # These are declared tree artifacts, not arbitrary source trees.
                # Reject internal links rather than following them outside the tree.
                if path.suffix != ".storyboardc" or not path.is_dir():
                    raise ValueError("expected compiled storyboard tree")
                if any(entry.is_symlink() for entry in path.rglob("*")):
                    raise ValueError("compiled storyboard contains a symlink")
                shutil.copytree(path, target)
            staged.append(str(target))
        home, tmp, compiled = state / "home", state / "tmp", state / "compiled"
        for directory in (home, tmp, compiled):
            directory.mkdir()
        rewritten = list(toolargs)
        rewritten[rewritten.index(option) + 1] = str(compiled)
        rewritten[-len(sources):] = staged
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
        result = compiled / output.name if mode == "compile" else compiled
        if not result.is_dir() or not any(result.iterdir()):
            raise ValueError("compiler did not produce its storyboard output")
        shutil.copytree(result, output, dirs_exist_ok=True)
    return 0
