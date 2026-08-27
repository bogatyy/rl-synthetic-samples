"""OpenRouter adapter with response-shape validation and lossless reasoning."""

from __future__ import annotations

from typing import Any

from minisweagent.models.openrouter_model import OpenRouterAPIError, OpenRouterModel


def _error_summary(response: Any) -> str:
    if not isinstance(response, dict):
        return f"unexpected {type(response).__name__} response"
    error = response.get("error")
    if isinstance(error, dict):
        code = error.get("code", "unknown")
        message = str(error.get("message", "provider error"))[:500]
        return f"provider error {code}: {message}"
    return "response did not contain a completion choice"


class OpenRouterReasoningModel(OpenRouterModel):
    """Retry HTTP-200 provider errors before the stock parser sees them.

    OpenRouter can return an error object with HTTP 200 when an upstream model
    provider fails. mini-swe-agent 2.4.6 retries transport exceptions but lets
    this response fall through to a ``KeyError('choices')``. Raising its own
    retryable API exception here activates the existing bounded retry policy.

    Valid responses are returned byte-for-byte, so Gemini ``reasoning`` and
    ``reasoning_details`` fields remain attached to their assistant messages.
    """

    def __init__(self, **kwargs: Any):
        configured_model_kwargs = kwargs.get("model_kwargs") or {}
        self._automatic_provider_affinity = "provider" not in configured_model_kwargs
        super().__init__(**kwargs)

    def _query(self, messages: list[dict[str, str]], **kwargs: Any) -> dict:
        response = super()._query(messages, **kwargs)
        choices = response.get("choices") if isinstance(response, dict) else None
        if not isinstance(choices, list) or not choices:
            raise OpenRouterAPIError(_error_summary(response))
        first = choices[0]
        if not isinstance(first, dict) or not isinstance(first.get("message"), dict):
            raise OpenRouterAPIError("completion choice did not contain a message")

        # Gemini's encrypted thought signatures are upstream-specific. Once a
        # provider has issued one, routing a later turn to another provider can
        # produce a 400 "Corrupted thought signature" response even though the
        # reasoning history was echoed exactly. Pin only OpenRouter Gemini runs,
        # and never override an explicit provider preference from the caller.
        provider = response.get("provider")
        if (
            self._automatic_provider_affinity
            and self.config.model_name.startswith("google/gemini-")
            and isinstance(provider, str)
            and provider
        ):
            self.config.model_kwargs["provider"] = {
                "order": [provider],
                "allow_fallbacks": False,
            }
            self._automatic_provider_affinity = False
        return response
