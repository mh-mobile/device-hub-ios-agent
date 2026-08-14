from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_SCRIPT = ROOT / "Scripts" / "archive-app.sh"
BUILD_SCRIPT = ROOT / "Scripts" / "build-app.sh"
SIGNING_HELPER = ROOT / "BuildSupport" / "signing_keychain.sh"


class ArchiveAppContractTests(unittest.TestCase):
    def test_archive_supports_explicit_unsigned_validation(self) -> None:
        contents = ARCHIVE_SCRIPT.read_text()

        self.assertIn('CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"', contents)
        self.assertIn('CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED"', contents)

    def test_archive_can_opt_into_xcode_managed_provisioning(self) -> None:
        contents = ARCHIVE_SCRIPT.read_text()

        self.assertIn(
            'ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"',
            contents,
        )
        self.assertIn('if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]', contents)
        self.assertIn("XCODEBUILD_ARGS+=(-allowProvisioningUpdates)", contents)

    def test_signed_archive_requires_and_scopes_a_build_keychain(self) -> None:
        contents = ARCHIVE_SCRIPT.read_text()

        self.assertIn(
            'SIGNING_KEYCHAIN_PATH="${SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"',
            contents,
        )
        self.assertIn('CODE_SIGN_KEYCHAIN="$SIGNING_KEYCHAIN_PATH"', contents)
        self.assertIn(
            'OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN_PATH"',
            contents,
        )
        self.assertNotIn("set-keychain-settings", contents)
        self.assertNotIn("default-keychain -s", contents)
        self.assertNotIn("list-keychains -s", contents)

    def test_signed_entrypoints_prepare_the_existing_login_keychain(self) -> None:
        helper = SIGNING_HELPER.read_text()
        archive = ARCHIVE_SCRIPT.read_text()
        build = BUILD_SCRIPT.read_text()

        self.assertIn("devicehub_unlock_signing_keychain", helper)
        self.assertIn("devicehub_default_signing_password_file", helper)
        self.assertIn("javi-air-keychain-password", helper)
        self.assertIn("javimini-keychain-password", helper)
        self.assertIn("login.keychain-db", helper)
        self.assertIn("set-key-partition-list", helper)
        self.assertIn("apple-tool:,apple:,codesign:", helper)
        self.assertNotIn("set-keychain-settings", helper)
        self.assertNotIn("default-keychain -s", helper)
        self.assertNotIn("list-keychains -s", helper)
        self.assertIn("BuildSupport/signing_keychain.sh", archive)
        self.assertIn("BuildSupport/signing_keychain.sh", build)
        self.assertIn("devicehub_default_signing_password_file", archive)
        self.assertIn("devicehub_default_signing_password_file", build)


if __name__ == "__main__":
    unittest.main()
