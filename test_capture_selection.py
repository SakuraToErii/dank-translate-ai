import io
import unittest
from unittest import mock

import capture_selection as capture


class CaptureSelectionTests(unittest.TestCase):
    def test_prefers_utf8_plain_text(self):
        self.assertEqual(
            capture.choose_text_mime(["text/uri-list", "text/plain", "text/plain;charset=utf-8"]),
            "text/plain;charset=utf-8",
        )

    def test_rejects_non_text_mime(self):
        self.assertIsNone(capture.choose_text_mime(["image/png", "text/uri-list"]))

    def test_unicode_character_limit(self):
        accepted = "你" * 100_000
        self.assertEqual(
            capture.read_limited_text(io.BytesIO(accepted.encode()), 100_000),
            accepted,
        )
        self.assertIsNone(
            capture.read_limited_text(io.BytesIO((accepted + "界").encode()), 100_000)
        )

    def test_detects_file_uri_list(self):
        self.assertTrue(
            capture.looks_like_file_list(
                "file:///tmp/a.txt\nfile:///tmp/b.txt",
                ["text/plain", "text/uri-list"],
            )
        )

    def test_missing_wl_paste_is_released_as_empty_mime_list(self):
        with mock.patch("capture_selection.subprocess.run", side_effect=FileNotFoundError):
            self.assertEqual(capture.list_mime_types(primary=True), [])

    def test_safe_clipboard_text_is_allowed(self):
        safe_values = (
            "Translate this ordinary sentence into Chinese.",
            "The password policy requires at least twelve characters.",
            "Internationalization",
            "OpenAI-compatible",
            "https://example.com/docs?chapter=translation",
        )
        for value in safe_values:
            with self.subTest(value=value):
                self.assertFalse(capture.looks_sensitive(value, ["text/plain"]))

    def test_structured_credentials_are_sensitive(self):
        sensitive_values = (
            "password = DemoOnly-123!",
            '"api_key": "fake_example_value"',
            "Authorization: Bearer fakeToken1234567890",
            "postgresql://demo:fake-password@example.com/db",
            "seed phrase: alpha beta gamma delta",
            "-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----",
        )
        for value in sensitive_values:
            with self.subTest(value=value):
                self.assertTrue(capture.looks_sensitive(value, ["text/plain"]))

    def test_known_token_and_standalone_password_shapes_are_sensitive(self):
        sensitive_values = (
            "github_pat_" + "FakeTokenValue1234567890_ABC",
            "AKIA" + "ABCDEFGHIJKLMNOP",
            "P@ssw0rd123!",
            "hunter2",
            "123456",
            "123 456",
            "8f14e45fceea167a5a36dedd4bea2543",
        )
        for value in sensitive_values:
            with self.subTest(value=value):
                self.assertTrue(capture.looks_sensitive(value, ["text/plain"]))

    def test_password_manager_mime_is_sensitive(self):
        self.assertTrue(
            capture.looks_sensitive(
                "ordinary-looking-value",
                ["text/plain", "x-kde-passwordManagerHint"],
            )
        )


if __name__ == "__main__":
    unittest.main()
