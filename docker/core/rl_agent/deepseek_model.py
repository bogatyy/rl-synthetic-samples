"""DeepSeek chat model with lossless thinking-history round trips.

DeepSeek thinking-mode responses return private reasoning separately from normal
assistant content. The field must be included on the matching assistant message
when that message is sent back on the next request. This model makes that
contract explicit instead of depending on whichever mini-swe-agent/LiteLLM
versions Pier happens to install.

The reasoning is retained only in the agent trajectory and model request. It is
never printed by this module.
"""

from __future__ import annotations

from typing import Any

from minisweagent.models.litellm_model import LitellmModel


def _get(value: Any, key: str, default: Any = None) -> Any:
    if isinstance(value, dict):
        return value.get(key, default)
    return getattr(value, key, default)


def _nonempty_reasoning(value: Any) -> str | None:
    return value if isinstance(value, str) and value.strip() else None


def _reasoning_from_message(message: Any) -> str | None:
    """Recover reasoning from normalized or raw LiteLLM response locations."""

    direct = _nonempty_reasoning(_get(message, "reasoning_content"))
    if direct:
        return direct

    provider_fields = _get(message, "provider_specific_fields", {}) or {}
    provider_reasoning = _nonempty_reasoning(_get(provider_fields, "reasoning_content"))
    if provider_reasoning:
        return provider_reasoning

    # mini-swe-agent stores the complete LiteLLM response under `extra.response`.
    # Recover from it if a future response-model serializer drops the top-level
    # provider field while preserving the raw response.
    extra = _get(message, "extra", {}) or {}
    response = _get(extra, "response")
    choices = _get(response, "choices", []) or []
    if choices:
        raw_message = _get(choices[0], "message", {}) or {}
        raw_reasoning = _nonempty_reasoning(_get(raw_message, "reasoning_content"))
        if raw_reasoning:
            return raw_reasoning
        raw_provider_fields = _get(raw_message, "provider_specific_fields", {}) or {}
        return _nonempty_reasoning(_get(raw_provider_fields, "reasoning_content"))

    return None


class DeepSeekReasoningModel(LitellmModel):
    """LiteLLM model that guarantees DeepSeek reasoning is echoed losslessly."""

    def _thinking_enabled(self) -> bool:
        kwargs = self.config.model_kwargs
        if kwargs.get("reasoning_effort") == "none":
            return False
        thinking = kwargs.get("thinking")
        return not (isinstance(thinking, dict) and thinking.get("type") == "disabled")

    def query(self, messages: list[dict[str, str]], **kwargs) -> dict:
        message = super().query(messages, **kwargs)
        if reasoning := _reasoning_from_message(message):
            # Keep the field on the trajectory message so it is available to the
            # next request and to resume/replay tooling.
            message["reasoning_content"] = reasoning
        return message

    def _prepare_messages_for_api(self, messages: list[dict]) -> list[dict]:
        prepared: list[dict] = []
        for message in messages:
            patched = dict(message)
            if patched.get("role") == "assistant" and self._thinking_enabled():
                reasoning = _reasoning_from_message(message)
                # A literal single space is DeepSeek/LiteLLM's accepted marker
                # for a tool-call turn on which the provider reported zero
                # reasoning tokens. It prevents old empty turns from causing a
                # warning on every later request without fabricating reasoning.
                patched["reasoning_content"] = reasoning or " "
            prepared.append(patched)
        return super()._prepare_messages_for_api(prepared)
