"""mini-swe local environment that keeps runner credentials out of bash tools."""

from __future__ import annotations

import os
import platform
import shlex
from typing import Any

from minisweagent.environments.local import LocalEnvironment, _run
from minisweagent.utils.serialize import recursive_merge


_PROXY_KEYS = {
    "ALL_PROXY",
    "HTTP_PROXY",
    "HTTPS_PROXY",
}
_SECRET_SUFFIXES = (
    "_ACCESS_KEY",
    "_API_KEY",
    "_PASSWORD",
    "_SECRET",
    "_TOKEN",
)
_TOOL_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


def sanitized_tool_env(source: dict[str, str]) -> dict[str, str]:
    """Return the environment visible to model-issued shell commands."""
    result: dict[str, str] = {}
    for key, value in source.items():
        upper = key.upper()
        if upper in _PROXY_KEYS:
            continue
        if (
            (upper.endswith("_RPC_URL") and upper != "RPC_URL")
            or upper.startswith(("ARCHIVE_RPC_", "FORK_", "RL_TASK_POLICY_"))
            or upper == "KEEP_ARCHIVE_RPC"
        ):
            continue
        if upper.endswith(_SECRET_SUFFIXES):
            # Foundry expects this conventional variable for `cast source`.
            # This exact literal is a non-secret marker for the local gateway.
            if upper == "ETHERSCAN_API_KEY" and value == "source-only":
                result[key] = value
            continue
        result[key] = value
    tool_home = source.get("RL_TOOL_HOME", "/home/rltool")
    result.update(
        {
            "HOME": tool_home,
            "LOGNAME": "rltool",
            "PATH": _TOOL_PATH,
            "SHELL": "/bin/bash",
            "USER": "rltool",
        }
    )
    return result


def unprivileged_tool_command(command: str, source: dict[str, str]) -> str:
    """Wrap a model command in a one-way privilege and capability drop."""
    uid = int(source.get("RL_TOOL_UID", "10001"))
    gid = int(source.get("RL_TOOL_GID", "10001"))
    if uid <= 0 or gid <= 0:
        raise ValueError("model tool UID and GID must be unprivileged")
    return " ".join(
        (
            "exec /usr/bin/setpriv",
            f"--reuid={uid}",
            f"--regid={gid}",
            "--clear-groups",
            "--no-new-privs",
            "--inh-caps=-all",
            "--ambient-caps=-all",
            "--bounding-set=-all",
            "/bin/bash --noprofile --norc -lc",
            shlex.quote(command),
        )
    )


class SecureLocalEnvironment(LocalEnvironment):
    """Execute tools locally without provider keys or outbound proxy access."""

    def execute(
        self, action: dict, cwd: str = "", *, timeout: int | None = None
    ) -> dict[str, Any]:
        command = action.get("command", "")
        cwd = cwd or self.config.cwd or os.getcwd()
        controller_environment = os.environ | self.config.env
        environment = sanitized_tool_env(controller_environment)
        command = unprivileged_tool_command(command, controller_environment)
        try:
            result = _run(command, cwd, environment, timeout or self.config.timeout)
            output = {
                "output": result.stdout,
                "returncode": result.returncode,
                "exception_info": "",
            }
        except Exception as error:
            raw_output = getattr(error, "output", None)
            raw_output = (
                raw_output.decode("utf-8", errors="replace")
                if isinstance(raw_output, bytes)
                else (raw_output or "")
            )
            output = {
                "output": raw_output,
                "returncode": -1,
                "exception_info": f"An error occurred while executing the command: {error}",
                "extra": {
                    "exception_type": type(error).__name__,
                    "exception": str(error),
                },
            }
        self._check_finished(output)
        return output

    def get_template_vars(self, **kwargs) -> dict[str, Any]:
        return recursive_merge(
            self.config.model_dump(),
            platform.uname()._asdict(),
            sanitized_tool_env(dict(os.environ)),
            kwargs,
        )
