import json
import tempfile
import unittest
from pathlib import Path

from scripts.prepare_client import computer_presets


class ComputerPresetTests(unittest.TestCase):
    def render(self, items):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'computers.json'
            path.write_text(json.dumps(items))
            return computer_presets(path)

    def computer(self, **changes):
        return dict(id='office', label='Office', address='desktop.example', port=21118, **changes)

    def test_source_text_is_escaped(self):
        item = self.computer()
        item['label'] = '电视 " \\ \n \u2028'
        source = self.render([item])
        payload = source.split('TvComputerPreset[] = ', 1)[1].removesuffix(';\n')
        self.assertEqual(json.loads(payload), [item])

    def test_credentials_rejected(self):
        with self.assertRaises(ValueError):
            self.render([self.computer(password='must-not-be-embedded')])

    def test_duplicate_endpoint_rejected(self):
        first = self.computer()
        second = dict(first, id='other', address='DESKTOP.EXAMPLE')
        with self.assertRaises(ValueError):
            self.render([first, second])

    def test_invalid_inputs_rejected(self):
        for changes in [{'port': True}, {'port': 0}, {'address': 'https://desktop.example'},
                        {'address': 'user@desktop.example'}, {'label': ' '}, {'id': '../other'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.render([dict(self.computer(), **changes)])


if __name__ == '__main__':
    unittest.main()
