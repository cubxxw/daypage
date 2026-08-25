#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from dsh import (
    DEFAULT_BASE_URL,
    DEFAULT_MODEL,
    DshConfigError,
    RuntimeConfig,
    build_dsh_command,
    dsh_package,
    parse_dotenv,
    read_pinned_version,
    resolve_dsh_home,
    resolve_runtime_config,
    safe_child_environment,
    select_dotenv,
    validate_deepseek_base_url,
    validate_secret_file_mode,
)


class DshLauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "repo"
        (self.root / ".dsh").mkdir(parents=True)
        (self.root / ".dsh/version").write_text("0.1.1-rc.2\n", encoding="utf-8")
        (self.root / ".dsh/daypage.patch.yml").write_text("[]\n", encoding="utf-8")
        self.env_file = self.base / "operator.env"
        self.write_env(
            "DEEPSEEK_API_KEY=sk-test-only\n"
            "DEEPSEEK_BASE_URL=https://api.deepseek.com/v1\n"
            "DEEPSEEK_MODEL=deepseek-v4-pro\n"
            "PATH=/must/not/be/imported\n"
            "LINEAR_API_KEY=linear-secret\n"
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_env(self, content: str, *, mode: int = 0o600) -> None:
        self.env_file.write_text(content, encoding="utf-8")
        self.env_file.chmod(mode)

    def runtime_config(self) -> RuntimeConfig:
        return resolve_runtime_config(
            root=self.root,
            explicit_env_file=self.env_file,
            explicit_home=self.base / "dsh-home",
            environ={"HOME": str(self.base), "PATH": "/safe/bin", "GH_TOKEN": "do-not-pass"},
        )

    def test_parse_dotenv_reads_only_selected_values(self) -> None:
        selection = parse_dotenv(self.env_file)
        self.assertEqual(
            set(selection.values),
            {"DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL"},
        )
        self.assertIn("PATH", selection.names)
        self.assertIn("LINEAR_API_KEY", selection.names)

    def test_parse_dotenv_supports_export_and_quotes_without_evaluation(self) -> None:
        self.write_env(
            "export DEEPSEEK_API_KEY='sk-$literal'\n"
            'DEEPSEEK_MODEL="deepseek-v4-pro"\n'
        )
        selection = parse_dotenv(self.env_file)
        self.assertEqual(selection.values["DEEPSEEK_API_KEY"], "sk-$literal")
        self.assertEqual(selection.values["DEEPSEEK_MODEL"], "deepseek-v4-pro")

    def test_parse_dotenv_rejects_duplicates(self) -> None:
        self.write_env("DEEPSEEK_API_KEY=one\nDEEPSEEK_API_KEY=two\n")
        with self.assertRaisesRegex(DshConfigError, "more than once"):
            parse_dotenv(self.env_file)

    def test_select_dotenv_rejects_extra_repo_variables(self) -> None:
        repository_env = self.root / ".env"
        repository_env.write_text(
            "DEEPSEEK_API_KEY=sk-test\nOPENAI_API_KEY=must-not-leak\n",
            encoding="utf-8",
        )
        repository_env.chmod(0o600)
        with self.assertRaisesRegex(DshConfigError, "outside the DSH allowlist"):
            select_dotenv(self.root, None)

    def test_secret_file_must_be_owner_only(self) -> None:
        self.env_file.chmod(0o644)
        with self.assertRaisesRegex(DshConfigError, "mode 0600"):
            validate_secret_file_mode(self.env_file)

    def test_official_base_url_accepts_root_and_v1(self) -> None:
        self.assertEqual(
            validate_deepseek_base_url("https://api.deepseek.com"),
            "https://api.deepseek.com",
        )
        self.assertEqual(
            validate_deepseek_base_url("https://api.deepseek.com/v1/"),
            "https://api.deepseek.com/v1",
        )
        self.assertEqual(
            validate_deepseek_base_url("https://api.deepseek.com:443/v1"),
            "https://api.deepseek.com:443/v1",
        )

    def test_custom_or_credentialed_endpoint_is_rejected(self) -> None:
        for value in (
            "https://example.com/v1",
            "http://api.deepseek.com",
            "https://api.deepseek.com:444/v1",
            "https://api.deepseek.com:invalid/v1",
            "https://user:pass@api.deepseek.com",
        ):
            with self.subTest(value=value):
                with self.assertRaises(DshConfigError):
                    validate_deepseek_base_url(value)

    def test_runtime_config_uses_selected_values_and_scrubs_other_secrets(self) -> None:
        config = self.runtime_config()
        self.assertEqual(config.deepseek_base_url, "https://api.deepseek.com/v1")
        self.assertEqual(config.deepseek_model, "deepseek-v4-pro")
        self.assertEqual(config.child_env["PATH"], "/safe/bin")
        self.assertNotIn("LINEAR_API_KEY", config.child_env)
        self.assertNotIn("GH_TOKEN", config.child_env)
        self.assertEqual(config.child_env["DSH_PERMISSION_MODE"], "workspace-write")
        self.assertEqual(config.child_env["DSH_TELEMETRY_DISABLED"], "1")
        self.assertEqual(config.child_env["DSH_TELEMETRY_MODE"], "DISABLED")

    def test_runtime_config_applies_safe_provider_defaults(self) -> None:
        self.write_env("DEEPSEEK_API_KEY=sk-test-only\n")
        config = self.runtime_config()
        self.assertEqual(config.deepseek_base_url, DEFAULT_BASE_URL)
        self.assertEqual(config.deepseek_model, DEFAULT_MODEL)

    def test_dsh_home_must_be_outside_repository(self) -> None:
        with self.assertRaisesRegex(DshConfigError, "outside the repository"):
            resolve_dsh_home(self.root, self.root / ".dsh-state", {})

    def test_child_environment_keeps_only_safe_process_values(self) -> None:
        child = safe_child_environment(
            {
                "HOME": str(self.base),
                "PATH": "/safe/bin",
                "OPENAI_API_KEY": "drop-me",
                "LC_ALL": "C",
            },
            {"DEEPSEEK_API_KEY": "sk-test-only"},
            self.base / "dsh-home",
        )
        self.assertEqual(child["LC_ALL"], "C")
        self.assertNotIn("OPENAI_API_KEY", child)

    def test_version_is_exact_and_package_reference_is_pinned(self) -> None:
        version = read_pinned_version(self.root)
        self.assertEqual(version, "0.1.1-rc.2")
        self.assertEqual(dsh_package(version), "@deepseek-ai/dsh@0.1.1-rc.2")

    def test_unpinned_version_is_rejected(self) -> None:
        (self.root / ".dsh/version").write_text("latest\n", encoding="utf-8")
        with self.assertRaisesRegex(DshConfigError, "exact semantic version"):
            read_pinned_version(self.root)

    @mock.patch("dsh.shutil.which", return_value="/safe/pnpm")
    def test_command_uses_pinned_web_profile_and_repository_patch(self, _which: mock.Mock) -> None:
        command = build_dsh_command(self.runtime_config(), "dump-config", [])
        self.assertEqual(command[:4], ["/safe/pnpm", "dlx", "@deepseek-ai/dsh@0.1.1-rc.2", "web"])
        self.assertIn(str(self.root / ".dsh/daypage.patch.yml"), command)
        self.assertEqual(command[-1], "--dump-config")

if __name__ == "__main__":
    unittest.main()
