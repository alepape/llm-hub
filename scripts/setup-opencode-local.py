#!/usr/bin/env python3
"""Configure OpenCode V2 for the existing local M4 Pro llama-swap service."""
import copy
import datetime
import json
import os
from pathlib import Path
import re
import shutil


def read_config(path):
    """Read JSONC without changing comment-like content inside strings."""
    text = path.read_text()
    strings = r'"(?:[^"\\]|\\.)*"'
    text = re.sub(
        rf'({strings})|//[^\n]*|/\*.*?\*/',
        lambda match: match.group(1) or '',
        text,
        flags=re.DOTALL,
    )
    text = re.sub(
        rf'({strings})|,\s*(?=[}}\]])',
        lambda match: match.group(1) or '',
        text,
    )
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError(f'{path}: expected a config object')
    return data


def setup(home, config_dir):
    template = json.loads(
        (Path(__file__).resolve().parent.parent / 'config/opencode/m4pro-local.json').read_text()
    )
    global_paths = [config_dir / name for name in ('opencode.json', 'opencode.jsonc')]
    global_paths = [path for path in global_paths if path.exists()] or [config_dir / 'opencode.json']
    inherited_paths = [
        home / '.opencode' / name for name in ('opencode.json', 'opencode.jsonc')
        if (home / '.opencode' / name).exists()
    ]
    updates = []
    # Parse and validate every affected file before writing any of them.
    for path in global_paths + inherited_paths:
        data = read_config(path) if path.exists() else {}
        updated = copy.deepcopy(data)
        updated.setdefault('$schema', template['$schema'])
        updated['model'] = template['model']
        # Repeat in inherited configs so an older home-level override cannot
        # replace this provider's local endpoint or model definition.
        updated.setdefault('providers', {})['m4pro-local'] = template['providers']['m4pro-local']
        if updated != data:
            updates.append((path, updated))
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    for path, data in updates:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            backup = path.with_name(path.name + '.bak-' + stamp)
            shutil.copy2(path, backup)
            backup.chmod(0o600)
            print(f'Backup: {backup}')
        # Normalize JSONC to JSON; the original comments remain in the backup.
        with open(path, 'w', opener=lambda name, flags: os.open(name, flags, 0o600)) as stream:
            json.dump(data, stream, indent=2)
            stream.write('\n')
        path.chmod(0o600)
        print(f'Updated: {path}')
    print('Default: m4pro-local/qwen35-35b -> http://127.0.0.1:8080/v1')
    print('Existing providers and MCPs preserved. Project model overrides still take precedence.')
    print('Start models separately: ./scripts/start-models.sh m4pro')
    print('In OpenCode: /reload, then /models for an existing session. New sessions use the default.')


if __name__ == '__main__':
    home = Path.home()
    try:
        setup(home, Path(os.environ.get('XDG_CONFIG_HOME', home / '.config')) / 'opencode')
    except (OSError, ValueError, TypeError) as error:
        raise SystemExit(f'Cannot configure local OpenCode: {error}')
