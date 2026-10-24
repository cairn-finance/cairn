#!/usr/bin/env python3
"""Exercise the Xcode Cloud bootstrap without an Apple account or SDK."""

from pathlib import Path
import subprocess
import tempfile
import unittest


BOOTSTRAP = Path(__file__).resolve().parents[2] / "ci_scripts/ci_post_clone.sh"


class XcodeCloudBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="cairn-cloud-")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.repository = self.root / "repository with spaces"
        (self.repository / "Config").mkdir(parents=True)
        self.tools = self.root / "bin"
        self.tools.mkdir()
        self.trace = self.root / "tool-calls"
        self.generator = self.root / "generator-template"
        self.generator.write_text("""#!/bin/sh
set -eu
printf 'xcodegen\\n' >> "$MOCK_TRACE"
if [ "${MOCK_GENERATOR_FAIL:-0}" = 1 ]; then exit 42; fi
if [ "${MOCK_GENERATOR_NO_PROJECT:-0}" = 0 ]; then
  mkdir -p Cairn.xcodeproj
  printf '// Generated project fixture\\n' > Cairn.xcodeproj/project.pbxproj
fi
""")
        self.install_tool("xcodegen", self.generator.read_text())
        self.install_tool("xcodebuild", "#!/bin/sh\nprintf 'Xcode 27.1\\n'\n")
        self.install_tool("xcrun", """#!/bin/sh
set -eu
[ "$*" = '--sdk iphoneos --show-sdk-version' ] || exit 4
printf '%s\\n' "${MOCK_IOS_SDK:-27.1}"
""")
        self.install_tool("brew", """#!/bin/sh
set -eu
[ "$*" = 'install xcodegen' ] || exit 5
printf 'brew install xcodegen\\n' >> "$MOCK_TRACE"
cp "$MOCK_GENERATOR_SOURCE" "$MOCK_BIN/xcodegen"
chmod +x "$MOCK_BIN/xcodegen"
""")
        self.environment = {
            "PATH": f"{self.tools}:/usr/bin:/bin",
            "CI_PRIMARY_REPOSITORY_PATH": str(self.repository),
            "CI_TEAM_ID": "ABCDE12345",
            "CI_BUNDLE_ID": "com.example.cairn",
            "ICLOUD_CONTAINER_ID": "iCloud.com.example.cairn.sync",
            "MOCK_TRACE": str(self.trace),
            "MOCK_BIN": str(self.tools),
            "MOCK_GENERATOR_SOURCE": str(self.generator),
        }

    def install_tool(self, name, source):
        tool = self.tools / name
        tool.write_text(source)
        tool.chmod(0o755)

    def run_bootstrap(self):
        # Cloud starts this script in ci_scripts, not in the repository root.
        return subprocess.run(
            ["/bin/sh", str(BOOTSTRAP)],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def calls(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def test_cloud_identity_generates_project_without_logging_identifiers(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repository / "Cairn.xcodeproj/project.pbxproj").is_file())
        settings = (self.repository / "Config/Signing.local.xcconfig").read_text()
        self.assertEqual(settings, "DEVELOPMENT_TEAM = ABCDE12345\n"
                         "CAIRN_HOST_BUNDLE_IDENTIFIER = com.example.cairn\n"
                         "ICLOUD_CONTAINER_ID = iCloud.com.example.cairn.sync\n")
        for name in ("CI_TEAM_ID", "CI_BUNDLE_ID", "ICLOUD_CONTAINER_ID"):
            self.assertNotIn(self.environment[name], result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["xcodegen"])

    def test_explicit_identity_overrides_cloud_defaults(self):
        self.environment.update(DEVELOPMENT_TEAM="FGHIJ67890",
                                PRODUCT_BUNDLE_IDENTIFIER="com.example.other")
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = (self.repository / "Config/Signing.local.xcconfig").read_text()
        self.assertIn("DEVELOPMENT_TEAM = FGHIJ67890\n", settings)
        self.assertIn("CAIRN_HOST_BUNDLE_IDENTIFIER = com.example.other\n", settings)

    def test_missing_container_does_not_guess_a_different_cloud_database(self):
        del self.environment["ICLOUD_CONTAINER_ID"]
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ICLOUD_CONTAINER_ID", result.stderr)
        self.assertFalse((self.repository / "Config/Signing.local.xcconfig").exists())
        self.assertEqual(self.calls(), [])

    def test_multiline_identifier_is_rejected(self):
        self.environment["ICLOUD_CONTAINER_ID"] = "iCloud.example\nOTHER = value"
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repository / "Config/Signing.local.xcconfig").exists())

    def test_older_sdk_stops_before_project_generation(self):
        self.environment["MOCK_IOS_SDK"] = "27.0"
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("iOS 27.1 SDK", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_generator_is_installed_with_homebrew(self):
        (self.tools / "xcodegen").unlink()
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["brew install xcodegen", "xcodegen"])

    def test_generator_failure_is_propagated(self):
        self.environment["MOCK_GENERATOR_FAIL"] = "1"
        self.assertEqual(self.run_bootstrap().returncode, 42)

    def test_success_without_project_is_rejected(self):
        self.environment["MOCK_GENERATOR_NO_PROJECT"] = "1"
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not create Cairn.xcodeproj", result.stderr)


if __name__ == "__main__":
    unittest.main()
