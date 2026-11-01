import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'setup_local', Path(__file__).resolve().parent.parent / 'scripts/setup-opencode-local.py'
)
setup_local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup_local)


class SetupLocalTests(unittest.TestCase):
    def test_merge_backup_and_idempotency(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / '.config/opencode'
            config.mkdir(parents=True)
            path = config / 'opencode.jsonc'
            original = '''{
              // preserve these settings, including comment-like strings
              "model": "llm-hub/auto",
              "mcp": {"servers": {"example": {"url": "http://host/mcp"}}},
              "providers": {"other": {"settings": {"apiKey": "/* secret */"}}},
            }'''
            path.write_text(original)
            inherited = home / '.opencode/opencode.json'
            inherited.parent.mkdir()
            inherited.write_text('{"model":"old/model"}')
            setup_local.setup(home, config)
            result = json.loads(path.read_text())
            self.assertEqual(result['model'], 'm4pro-local/qwen35-35b')
            self.assertEqual(result['mcp']['servers']['example']['url'], 'http://host/mcp')
            self.assertEqual(result['providers']['other']['settings']['apiKey'], '/* secret */')
            self.assertEqual(json.loads(inherited.read_text())['model'], result['model'])
            backups = list(home.rglob('*.bak-*'))
            self.assertEqual(len(backups), 2)
            self.assertEqual(next(config.glob('*.bak-*')).read_text(), original)
            setup_local.setup(home, config)
            self.assertEqual(list(home.rglob('*.bak-*')), backups)

    def test_invalid_config_does_not_write_anything(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / '.config/opencode'
            config.mkdir(parents=True)
            first = config / 'opencode.json'
            first.write_text('{}')
            (config / 'opencode.jsonc').write_text('{broken')
            with self.assertRaises(ValueError):
                setup_local.setup(home, config)
            self.assertEqual(first.read_text(), '{}')
            self.assertFalse(list(config.glob('*.bak-*')))

    def test_fresh_install(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'custom-config/opencode'
            setup_local.setup(home, config)
            result = json.loads((config / 'opencode.json').read_text())
            self.assertEqual(
                result['providers']['m4pro-local']['settings']['baseURL'],
                'http://127.0.0.1:8080/v1',
            )


if __name__ == '__main__':
    unittest.main()
