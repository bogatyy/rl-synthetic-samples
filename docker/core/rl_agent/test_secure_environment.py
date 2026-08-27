from __future__ import annotations

import unittest

from rl_agent.secure_environment import (
    sanitized_tool_env,
    unprivileged_tool_command,
)


class ToolEnvironmentTests(unittest.TestCase):
    def test_provider_and_proxy_credentials_are_removed(self):
        result = sanitized_tool_env(
            {
                "DEEPSEEK_API_KEY": "secret",
                "HTTP_PROXY": "http://user:secret@proxy:8080",
                "https_proxy": "http://user:secret@proxy:8080",
                "RPC_URL": "http://pier-policy:8545",
            }
        )
        self.assertNotIn("DEEPSEEK_API_KEY", result)
        self.assertNotIn("HTTP_PROXY", result)
        self.assertNotIn("https_proxy", result)
        self.assertEqual(result["RPC_URL"], "http://pier-policy:8545")

    def test_only_dummy_explorer_key_survives(self):
        safe = sanitized_tool_env({"ETHERSCAN_API_KEY": "source-only"})
        unsafe = sanitized_tool_env({"ETHERSCAN_API_KEY": "real-secret"})
        self.assertEqual(safe["ETHERSCAN_API_KEY"], "source-only")
        self.assertNotIn("ETHERSCAN_API_KEY", unsafe)

    def test_archive_credentials_are_removed(self):
        result = sanitized_tool_env(
            {
                "ETH_RPC_URL": "secret",
                "BASE_RPC_URL": "secret",
                "ARCHIVE_RPC_URL": "secret",
                "RL_TASK_POLICY_ARCHIVE_RPC": "secret",
                "FORK_BLOCK_NUMBER": "25541000",
                "FORK_TARGET_TIMESTAMP": "1777388411",
                "KEEP_ARCHIVE_RPC": "1",
                "RPC_URL": "http://pier-policy:8545",
            }
        )
        self.assertEqual(result["RPC_URL"], "http://pier-policy:8545")
        self.assertEqual(result["HOME"], "/home/rltool")
        self.assertEqual(result["USER"], "rltool")
        self.assertNotIn("ARCHIVE_RPC_URL", result)
        self.assertNotIn("FORK_BLOCK_NUMBER", result)
        self.assertNotIn("FORK_TARGET_TIMESTAMP", result)
        self.assertNotIn("KEEP_ARCHIVE_RPC", result)

    def test_tool_command_drops_root_and_all_capabilities(self):
        wrapped = unprivileged_tool_command(
            "printf '%s' \"$DEEPSEEK_API_KEY\"", {"RL_TOOL_UID": "10001", "RL_TOOL_GID": "10001"}
        )
        self.assertIn("--reuid=10001", wrapped)
        self.assertIn("--regid=10001", wrapped)
        self.assertIn("--clear-groups", wrapped)
        self.assertIn("--no-new-privs", wrapped)
        self.assertIn("--bounding-set=-all", wrapped)
        self.assertTrue(wrapped.startswith("exec /usr/bin/setpriv "))

    def test_root_tool_identity_is_rejected(self):
        with self.assertRaises(ValueError):
            unprivileged_tool_command("true", {"RL_TOOL_UID": "0", "RL_TOOL_GID": "10001"})


if __name__ == "__main__":
    unittest.main()
