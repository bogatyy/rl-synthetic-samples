from __future__ import annotations

import unittest
from unittest.mock import patch

from minisweagent.models.openrouter_model import OpenRouterAPIError, OpenRouterModel
from rl_agent.openrouter_model import OpenRouterReasoningModel


class OpenRouterReasoningModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.model = OpenRouterReasoningModel(
            model_name="google/gemini-3.1-pro-preview",
            model_kwargs={"reasoning_effort": "high"},
            cost_tracking="ignore_errors",
        )

    def test_valid_response_is_unchanged(self) -> None:
        response = {
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": "working",
                        "reasoning": "private trace",
                        "reasoning_details": [{"type": "reasoning.text", "text": "trace"}],
                    }
                }
            ],
            "provider": "Google",
        }
        with patch.object(OpenRouterModel, "_query", return_value=response):
            self.assertIs(self.model._query([]), response)
        self.assertEqual(
            self.model.config.model_kwargs["provider"],
            {"order": ["Google"], "allow_fallbacks": False},
        )

    def test_explicit_provider_preference_is_preserved(self) -> None:
        preference = {"order": ["Google AI Studio"], "allow_fallbacks": False}
        model = OpenRouterReasoningModel(
            model_name="google/gemini-3.1-pro-preview",
            model_kwargs={"provider": preference},
            cost_tracking="ignore_errors",
        )
        response = {
            "choices": [{"message": {"role": "assistant", "content": "ok"}}],
            "provider": "Google",
        }
        with patch.object(OpenRouterModel, "_query", return_value=response):
            model._query([])
        self.assertEqual(model.config.model_kwargs["provider"], preference)

    def test_http_200_provider_error_is_retryable(self) -> None:
        response = {"error": {"code": 503, "message": "upstream unavailable"}}
        with patch.object(OpenRouterModel, "_query", return_value=response):
            with self.assertRaises(OpenRouterAPIError):
                self.model._query([])

    def test_empty_choices_is_retryable(self) -> None:
        with patch.object(OpenRouterModel, "_query", return_value={"choices": []}):
            with self.assertRaises(OpenRouterAPIError):
                self.model._query([])


if __name__ == "__main__":
    unittest.main()
