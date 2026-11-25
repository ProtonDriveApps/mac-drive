"""Read the product release version and expand versioned plist templates."""
import argparse
import json
from pathlib import Path
import re


def read_version(path):
    version = Path(path).read_text().strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('VERSION must contain a release version in major.minor.patch format')
    return version


def render_plist(template, substitutions, version_file):
    substitutions = dict(substitutions)
    substitutions['$(MARKETING_VERSION)'] = read_version(version_file)
    for key, value in substitutions.items():
        template = template.replace(key, value)
    return template


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version-file', type=Path, required=True)
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--substitutions', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = render_plist(args.template.read_text(),
                              json.loads(args.substitutions.read_text()), args.version_file)
    except ValueError as error:
        parser.error(str(error))
    args.output.write_text(result)


if __name__ == '__main__':
    main()
