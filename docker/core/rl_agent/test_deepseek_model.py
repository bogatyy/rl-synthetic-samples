from __future__ import annotations

import unittest
from unittest.mock import patch

from rl_agent.deepseek_model import DeepSeekReasoningModel
from minisweagent.models.litellm_model import LitellmModel


class DeepSeekReasoningModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.model = DeepSeekReasoningModel(
            model_name="deepseek/deepseek-v4-flash",
            model_kwargs={"reasoning_effort": "max"},
            cost_tracking="ignore_errors",
        )

    def test_preserves_top_level_reasoning(self) -> None:
        prepared = self.model._prepare_messages_for_api(
            [{"role": "assistant", "content": "", "reasoning_content": "trace-a"}]
        )
        self.assertEqual(prepared[0]["reasoning_content"], "trace-a")

    def test_promotes_provider_specific_reasoning(self) -> None:
        prepared = self.model._prepare_messages_for_api(
            [
                {
                    "role": "assistant",
                    "content": "",
                    "provider_specific_fields": {"reasoning_content": "trace-b"},
                }
            ]
        )
        self.assertEqual(prepared[0]["reasoning_content"], "trace-b")

    def test_recovers_reasoning_from_raw_response(self) -> None:
        prepared = self.model._prepare_messages_for_api(
            [
                {
                    "role": "assistant",
                    "content": "",
                    "extra": {
                        "response": {
                            "choices": [{"message": {"reasoning_content": "trace-c"}}]
                        }
                    },
                }
            ]
        )
        self.assertEqual(prepared[0]["reasoning_content"], "trace-c")
        self.assertNotIn("extra", prepared[0])

    def test_query_keeps_recovered_reasoning_in_trajectory_message(self) -> None:
        response_message = {
            "role": "assistant",
            "content": "",
            "extra": {
                "response": {
                    "choices": [{"message": {"reasoning_content": "trace-d"}}]
                }
            },
        }
        with patch.object(LitellmModel, "query", return_value=response_message):
            result = self.model.query([])
        self.assertEqual(result["reasoning_content"], "trace-d")

    def test_marks_genuine_zero_reasoning_turn(self) -> None:
        prepared = self.model._prepare_messages_for_api(
            [{"role": "assistant", "content": "", "tool_calls": []}]
        )
        self.assertEqual(prepared[0]["reasoning_content"], " ")

    def test_does_not_mark_when_thinking_is_disabled(self) -> None:
        model = DeepSeekReasoningModel(
            model_name="deepseek/deepseek-v4-flash",
            model_kwargs={"reasoning_effort": "none"},
            cost_tracking="ignore_errors",
        )
        prepared = model._prepare_messages_for_api(
            [{"role": "assistant", "content": "plain"}]
        )
        self.assertNotIn("reasoning_content", prepared[0])


if __name__ == "__main__":
    unittest.main()
