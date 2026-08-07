#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from doctor import validate_contracts


VALID_SKILL = """\
---
name: fixture-skill
description: A portable fixture skill.
---

# Fixture
"""

VALID_AGENT = """\
name = "explorer"
description = "Read-only fixture explorer."
model = "gpt-5.4"
model_reasoning_effort = "medium"
sandbox_mode = "read-only"
developer_instructions = "Inspect only."
"""

VALID_MANIFEST = """\
schema_version: 1
canonical_root: .agents
constitution: AGENTS.md
documentation_index: AGENTS.md
roles:
  explorer: .agents/roles/explorer.md
workflows:
  intake: .agents/workflows/intake.md
contracts:
  task: .agents/schemas/task.schema.json
templates:
  task: .agents/templates/task.md
skills:
  fixture-skill:
    canonical: .agents/skills/fixture/SKILL.md
codex:
  config: .codex/config.toml
  agent_directory: .codex/agents
  role_adapters:
    explorer: .codex/agents/explorer.toml
"""

VALID_SCHEMA = """\
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://daypage.local/schemas/task.schema.json",
  "type": "object",
  "additionalProperties": false,
  "required": ["task_id"],
  "properties": {
    "task_id": {"type": "string"}
  }
}
"""


class DoctorContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.write("AGENTS.md", "# Fixture\n")
        self.write(".agents/manifest.yaml", VALID_MANIFEST)
        self.write(
            ".agents/roles/explorer.md",
            "---\nname: explorer\nmission: Inspect.\n---\n\n# Explorer\n",
        )
        self.write(
            ".agents/workflows/intake.md",
            "---\nname: intake\ntrigger: A request.\n---\n\n# Intake\n",
        )
        self.write(".agents/schemas/task.schema.json", VALID_SCHEMA)
        self.write(".agents/templates/task.md", "# Task\n")
        self.write(".agents/skills/fixture/SKILL.md", VALID_SKILL)
        self.write(".codex/config.toml", "# Fixture config.\n")
        self.write(".codex/agents/explorer.toml", VALID_AGENT)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "user.name", "Fixture")
        self.git("add", ".")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, path: str, content: str) -> None:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(textwrap.dedent(content), encoding="utf-8")

    def git(self, *args: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.root), *args],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def codes(self) -> set[str]:
        return {finding.code for finding in validate_contracts(self.root)}

    def test_valid_fixture_passes(self) -> None:
        self.assertEqual(self.codes(), set())

    def test_invalid_skill_frontmatter_is_detected(self) -> None:
        self.write(".agents/skills/fixture/SKILL.md", "# no metadata\n")
        self.assertIn("skill.frontmatter", self.codes())

    def test_missing_manifest_is_detected(self) -> None:
        (self.root / ".agents/manifest.yaml").unlink()
        self.assertIn("manifest.missing", self.codes())

    def test_invalid_manifest_mapping_is_detected(self) -> None:
        self.write(".agents/manifest.yaml", "roles:\n   explorer: broken-indent\n")
        self.assertIn("manifest.syntax", self.codes())

    def test_missing_manifest_reference_is_detected(self) -> None:
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace(
                ".agents/templates/task.md",
                ".agents/templates/missing.md",
            ),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_missing_top_level_manifest_reference_is_detected(self) -> None:
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace("constitution: AGENTS.md", "constitution: missing.md"),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_absolute_manifest_reference_is_detected(self) -> None:
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace(
                ".agents/roles/explorer.md",
                "/etc/passwd",
            ),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_manifest_symlink_resolving_outside_repo_is_detected(self) -> None:
        link = self.root / ".agents/roles/outside.md"
        link.symlink_to("/etc/passwd")
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace(
                ".agents/roles/explorer.md",
                ".agents/roles/outside.md",
            ),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_manifest_reference_wrong_section_is_detected(self) -> None:
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace(
                ".agents/roles/explorer.md",
                ".agents/templates/task.md",
            ),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_manifest_reference_wrong_type_is_detected(self) -> None:
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace(
                "canonical_root: .agents",
                "canonical_root: AGENTS.md",
            ),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_manifest_reference_must_be_a_path(self) -> None:
        self.write(
            ".agents/manifest.yaml",
            VALID_MANIFEST.replace(
                "task: .agents/templates/task.md",
                "task: false",
            ),
        )
        self.assertIn("manifest.reference", self.codes())

    def test_manifest_required_section_is_detected(self) -> None:
        manifest = VALID_MANIFEST.replace(
            "templates:\n  task: .agents/templates/task.md\n",
            "",
        )
        self.write(".agents/manifest.yaml", manifest)
        self.assertIn("manifest.section", self.codes())

    def test_role_frontmatter_must_match_manifest_key(self) -> None:
        self.write(
            ".agents/roles/explorer.md",
            "---\nname: reviewer\nmission: Wrong identity.\n---\n",
        )
        self.assertIn("role.name", self.codes())

    def test_workflow_frontmatter_must_match_manifest_key(self) -> None:
        self.write(
            ".agents/workflows/intake.md",
            "---\nname: release\ntrigger: Wrong identity.\n---\n",
        )
        self.assertIn("workflow.name", self.codes())

    def test_personal_absolute_path_is_detected(self) -> None:
        self.write(".agents/README.md", "Use /Users/alice/private/daypage.\n")
        self.assertIn("path.personal", self.codes())

    def test_root_readme_personal_absolute_path_is_detected(self) -> None:
        self.write("README.md", "Use /Users/alice/private/daypage.\n")
        self.assertIn("path.personal", self.codes())

    def test_known_stale_project_fact_is_detected(self) -> None:
        self.write(".agents/README.md", "DayPage has a single Xcode target.\n")
        self.assertIn("fact.stale", self.codes())

    def test_root_readme_stale_project_fact_is_detected(self) -> None:
        self.write("README.md", "DayPage has a single Xcode target.\n")
        self.assertIn("fact.stale", self.codes())

    def test_tracked_run_artifact_is_detected(self) -> None:
        self.write(".agents/skills/fixture/runs/run-1/report.json", "{}\n")
        self.git("add", ".agents/skills/fixture/runs/run-1/report.json")
        self.assertIn("runs.tracked", self.codes())

    def test_missing_codex_agent_field_is_detected(self) -> None:
        self.write(
            ".codex/agents/explorer.toml",
            'name = "explorer"\ndescription = "Missing instructions."\n',
        )
        self.assertIn("agent.field", self.codes())

    def test_duplicate_codex_agent_name_is_detected(self) -> None:
        self.write(
            ".codex/agents/duplicate.toml",
            VALID_AGENT.replace("Read-only fixture explorer.", "Duplicate fixture explorer."),
        )
        self.assertIn("agent.name", self.codes())

    def test_codex_adapter_name_must_match_manifest_key(self) -> None:
        self.write(
            ".codex/agents/explorer.toml",
            VALID_AGENT.replace('name = "explorer"', 'name = "reviewer"'),
        )
        self.assertIn("agent.manifest-name", self.codes())

    def test_invalid_codex_root_config_is_detected(self) -> None:
        self.write(".codex/config.toml", "[agents\ninvalid = true\n")
        self.assertIn("config.toml", self.codes())

    def test_unpinned_npx_server_is_detected(self) -> None:
        self.write(
            ".codex/config.toml",
            """\
            [mcp_servers.example]
            command = "npx"
            args = ["-y", "@example/server@latest"]
            """,
        )
        self.assertIn("command.unpinned", self.codes())

    def test_invalid_json_schema_is_detected(self) -> None:
        self.write(".agents/schemas/task.schema.json", '{"type": "object",')
        self.assertIn("schema.json", self.codes())

    def test_json_schema_required_property_is_detected(self) -> None:
        self.write(
            ".agents/schemas/task.schema.json",
            VALID_SCHEMA.replace('"required": ["task_id"]', '"required": ["missing"]'),
        )
        self.assertIn("schema.required", self.codes())

    def test_invalid_json_schema_min_length_is_detected(self) -> None:
        self.write(
            ".agents/schemas/task.schema.json",
            VALID_SCHEMA.replace(
                '"task_id": {"type": "string"}',
                '"task_id": {"type": "string", "minLength": "bad"}',
            ),
        )
        self.assertIn("schema.length", self.codes())

    def test_invalid_json_schema_composition_is_detected(self) -> None:
        self.write(
            ".agents/schemas/task.schema.json",
            VALID_SCHEMA.replace(
                '"additionalProperties": false,',
                '"additionalProperties": false, "allOf": {},',
            ),
        )
        self.assertIn("schema.composition", self.codes())

    def test_default_remote_write_is_detected(self) -> None:
        self.write(".agents/workflows/default.md", "```sh\ngit push origin main\n```\n")
        self.assertIn("remote-write.default", self.codes())

    def test_explicit_remote_write_marker_is_accepted(self) -> None:
        self.write(
            ".agents/workflows/release.md",
            "# agent-contract: explicit-user-action\n```sh\n"
            "# agent-contract: explicit-user-action\n"
            "git push origin release\n```\n",
        )
        self.assertNotIn("remote-write.default", self.codes())


if __name__ == "__main__":
    unittest.main()
