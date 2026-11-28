import copy
import unittest

import upstream_pin


class UpstreamPinTests(unittest.TestCase):
    def test_reviewed_pin(self):
        pin = upstream_pin.load()
        self.assertEqual(upstream_pin.installer_url(pin),
                         f"{upstream_pin.REPOSITORY_URL}/releases/download/v{pin['pulse_source_version']}/{pin['installer']['filename']}")

    def test_reject_mismatched_installer_and_incomplete_headers(self):
        for field, value in (("filename", "../untrusted.exe"), ("size", 0),
                             ("size", upstream_pin.MAX_INSTALLER_SIZE + 1),
                             ("sha256", "bad")):
            with self.subTest(field=field):
                pin = copy.deepcopy(upstream_pin.load())
                pin["installer"][field] = value
                with self.assertRaises(ValueError):
                    upstream_pin.validate(pin)
        pin = copy.deepcopy(upstream_pin.load())
        del pin["headers"]["abi"]
        with self.assertRaises(ValueError):
            upstream_pin.validate(pin)

    def test_added_header_names_are_validated(self):
        pin = copy.deepcopy(upstream_pin.load())
        pin["headers"]["future_sdk"] = "a" * 64
        upstream_pin.validate(pin)
        pin["headers"]["../unsafe"] = "b" * 64
        with self.assertRaises(ValueError):
            upstream_pin.validate(pin)

    def test_reject_other_source(self):
        pin = copy.deepcopy(upstream_pin.load())
        pin["repository"] = "https://example.com/pulse"
        with self.assertRaises(ValueError):
            upstream_pin.validate(pin)


if __name__ == "__main__":
    unittest.main()
