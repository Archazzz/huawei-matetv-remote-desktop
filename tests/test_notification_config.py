import base64
import copy
import json
import tempfile
import unittest
from pathlib import Path
from scripts.prepare_client import notification_configuration


class NotificationConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'pairing.json'
        self.dest = self.root / 'generated'
        self.valid = dict(version=1, endpoint='https://127.0.0.1:24443', token='x' * 43,
                          caResource='screenlink-notifications-ca.pem',
                          publicKeyHash=base64.b64encode(bytes(range(32))).decode())
        (self.root / self.valid['caResource']).write_text(
            '-----BEGIN CERTIFICATE-----\nfixture-not-used-for-network\n-----END CERTIFICATE-----\n')

    def apply(self, value):
        self.config.write_text(json.dumps(value))
        notification_configuration(self.config, self.dest)

    def test_valid_pairing_writes_only_bounded_resources(self):
        self.apply(self.valid)
        raw = self.dest / 'entry/src/main/resources/rawfile'
        self.assertEqual(json.loads((raw / 'screenlink-notifications.json').read_text()), self.valid)
        self.assertEqual(set(p.name for p in raw.iterdir()),
                         {'screenlink-notifications.json', 'screenlink-notifications-ca.pem'})

    def test_rejects_unsafe_origin_token_resource_and_pin_before_writing(self):
        cases = [('endpoint', 'http://127.0.0.1:24443'),
                 ('endpoint', 'https://user:password@example.com:443'),
                 ('endpoint', 'https://example.com:443/redirect'),
                 ('endpoint', 'https://example.com:65536'),
                 ('token', 'short'), ('token', 'x' * 32 + '\nHeader: bad'),
                 ('caResource', '../private.key'), ('publicKeyHash', 'invalid'),
                 ('publicKeyHash', base64.b64encode(b'short').decode())]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                item = copy.deepcopy(self.valid); item[key] = value
                with self.assertRaises(ValueError): self.apply(item)
                self.assertFalse(self.dest.exists())

    def test_rejects_unknown_fields_and_missing_ca(self):
        item = dict(self.valid, remotePassword='must-never-be-embedded')
        with self.assertRaises(ValueError): self.apply(item)
        (self.root / self.valid['caResource']).unlink()
        with self.assertRaises(FileNotFoundError): self.apply(self.valid)
        self.assertFalse(self.dest.exists())

    def test_private_key_cannot_be_used_as_ca(self):
        (self.root / self.valid['caResource']).write_text('-----BEGIN PRIVATE KEY-----\nsecret')
        with self.assertRaises(ValueError): self.apply(self.valid)
        self.assertFalse(self.dest.exists())
