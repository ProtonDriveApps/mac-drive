"""Run the reviewed Bazel binary with checkout-local action state."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

try:
    from .apple_toolchain import capture, verify, cache_identities
except ImportError:
    from apple_toolchain import capture, verify, cache_identities


BAZEL_CHECKSUMS = {
    ('9.3.3', 'arm64'): '5bcb76f9e94651f1eeec72243a69b03b4cd589c104611c583a59d4abbf9ea15a',
    ('9.3.3', 'x86_64'): '091ff8dd8ccda4cb0bd79af66b353d47d4f5d36de507fe0ac94c99ea918c17b3',
}
ACTION_COMMANDS = ('build', 'test', 'run', 'coverage', 'aquery', 'cquery')


def output_base(root):
    return Path(root).resolve() / '.build/bazel/output-base'


def bazel_path(root):
    version = (root / '.bazelversion').read_text().strip()
    return root / '.build/tools' / f'bazel-{version}-{platform.machine()}'


def bootstrap(root):
    version = (root / '.bazelversion').read_text().strip()
    architecture = platform.machine()
    expected = BAZEL_CHECKSUMS.get((version, architecture))
    if expected is None:
        raise ValueError(f'No reviewed Bazel checksum for {version} on {architecture}.')
    destination = bazel_path(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.with_name(destination.name + '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.is_file() and not destination.is_symlink():
            with destination.open('rb') as stream:
                actual = hashlib.sha256(stream.read()).hexdigest()
            if actual == expected:
                destination.chmod(0o755)
                print(f'Bazel {version} is already installed and verified.')
                return destination
        # Unique staging on the destination filesystem keeps incomplete bytes
        # away from the executable during concurrent and interrupted installs.
        with tempfile.TemporaryDirectory(prefix=destination.name + '-', dir=destination.parent) as temporary:
            download = Path(temporary) / 'download'
            url = f'https://github.com/bazelbuild/bazel/releases/download/{version}/bazel-{version}-darwin-{architecture}'
            subprocess.run(['curl', '--fail', '--location', '--output', str(download), url], check=True)
            with download.open('rb') as stream:
                actual = hashlib.sha256(stream.read()).hexdigest()
            if actual != expected:
                raise ValueError(f'Bazel checksum mismatch: expected {expected}, observed {actual}.')
            download.chmod(0o755)
            os.replace(download, destination)
    print(f'Installed Bazel {version} at {destination}.')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bootstrap', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--debug', action='store_true', help='Print selected Bazel rc options.')
    parser.add_argument('--fresh-build', action='store_true', help='Use independent local action state for build/test/coverage, retaining dependency downloads.')
    parser.add_argument('bazel_args', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if options.bootstrap:
        if options.bazel_args or options.debug or options.fresh_build:
            parser.error('--bootstrap accepts no Bazel arguments')
        try:
            bootstrap(root)
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            parser.exit(1, f'{error}\n')
        return 0
    arguments = options.bazel_args
    if arguments[:1] == ['--']:
        arguments = arguments[1:]
    if not arguments:
        parser.error('provide a Bazel command after --')
    if arguments[0].startswith('-'):
        parser.error('start with a Bazel command; startup options are managed by this wrapper (use --fresh-build for independent state)')
    if options.fresh_build and arguments[0] not in ('build', 'test', 'coverage'):
        parser.error('--fresh-build supports only build, test, and coverage')
    separator = arguments.index('--') if '--' in arguments else len(arguments)
    bazel_arguments, application_arguments = arguments[:separator], arguments[separator:]
    debug = options.debug or '--debug' in bazel_arguments
    bazel_arguments = [argument for argument in bazel_arguments if argument != '--debug']
    command_name = bazel_arguments[0]
    factory = os.environ.get('DRIVE_VALIDATION_ADAPTER') == 'factory'
    if factory and os.environ.get('GITLAB_CI') == 'true':
        parser.error('the factory adapter must not run with GITLAB_CI=true')
    if factory and any(argument == '--config=ci' or (argument == '--config' and following == 'ci') or
                       re.fullmatch(r'--remote_upload_local_results(=(true|yes|1))?', argument)
                       for argument, following in zip(bazel_arguments, bazel_arguments[1:] + [None])):
        parser.error('the factory adapter reads the remote cache but never uploads to it')
    if not (root / 'PDLocalization/BUILD.bazel').is_file() or not (root / 'ProtonDrive-macOS').is_dir():
        parser.error(f'not a native mac-drive Bazel checkout: {root}')
    launcher = bazel_path(root)
    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        parser.error('pinned Bazel is missing; run tools/bootstrap-bazel')
    state = root / '.build/bazel'
    shared = state / 'shared'
    environment = dict(os.environ)
    environment['DRIVE_MAC_ROOT'] = str(root)
    managed = [f'--repository_cache={shared / "repository-cache"}', '--repo_env=DRIVE_MAC_ROOT']
    if debug:
        managed.append('--announce_rc')
    if command_name in ('build', 'test', 'run', 'coverage'):
        if environment.get('GITLAB_CI') == 'true':
            bazel_arguments.insert(1, '--config=ci')
        if factory:
            managed.append('--noremote_upload_local_results')
        managed.append('--symlink_prefix=/')
        if not options.fresh_build:
            managed.append(f'--disk_cache={shared / "disk-cache"}')
    observed = None
    if command_name in ACTION_COMMANDS:
        try:
            observed = capture(environment=environment)
            verify(root, observed)
            observed_host, observed_xcode = cache_identities(observed)
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            parser.exit(1, f'{error}\n')
        environment['DEVELOPER_DIR'] = observed['developer_dir']
        managed += [f'--repo_env=XCODE_VERSION={observed["xcode"]["version"]}',
                    f'--xcode_version={observed["xcode"]["version"]}']
        for prefix in ('--action_env=', '--host_action_env='):
            managed += [prefix + 'DRIVE_BUILD_HOST=' + observed_host,
                        prefix + 'DRIVE_BUILD_XCODE=' + observed_xcode]
    startup = [f'--output_user_root={state / "output-user-root"}', f'--output_base={output_base(root)}']
    if options.fresh_build:
        verification = state / 'results/verification'
        verification.mkdir(parents=True, exist_ok=True)
        run_root = Path(tempfile.mkdtemp(prefix='run-', dir=verification))
        startup = ['--batch', f'--output_user_root={run_root / "output-user-root"}',
                   f'--output_base={run_root / "output-base"}']
        managed += ['--disk_cache=', '--remote_cache=', '--remote_executor=',
                    '--noremote_accept_cached', '--noremote_upload_local_results', '--repo_contents_cache=',
                    f'--execution_log_json_file={run_root / "execution.json"}']
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        (run_root / 'identity.json').write_text(json.dumps({
            'checkout': str(root), 'source_commit': commit,
            'bazel_version': (root / '.bazelversion').read_text().strip(),
            'host_identity': observed_host, 'xcode_identity': observed_xcode,
            'toolchain': observed,
            'scope': 'Independent local action state; source/host immutability is not verified.',
        }, indent=2) + '\n')
        print(f'Fresh build results: {run_root}', file=sys.stderr, flush=True)
    os.chdir(root)
    os.execve(str(launcher), [str(launcher), *startup, *bazel_arguments, *managed, *application_arguments], environment)


if __name__ == '__main__':
    sys.exit(main())
