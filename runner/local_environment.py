"""Pier Docker environment for isolated, fully local EVM tasks."""

from __future__ import annotations

import json
import re
from typing import Any

from pier.environments.docker.docker import DockerEnvironment


POLICY_SERVICE = "pier-policy"
ANVIL_SERVICE = "pier-anvil"
AGENT_NETWORK = "pier-egress-internal"
BACKEND_NETWORK = "pier-chain-backend"


def preserve_shared_images(command: list[str]) -> list[str]:
    """Keep task images when Pier tears down a trial's Compose project."""
    if command[:3] == ["down", "--rmi", "all"]:
        return ["down", *command[3:]]
    return command


def add_local_services(
    compose: dict[str, Any],
    *,
    image: str,
    chain_id: str,
    hardfork: str,
    scenario_contract: str | None,
    scenario_setup_script: str | None,
    scenario_target_address: str,
    scenario_source_path: str | None,
    scenario_source_registry: str | None,
    scenario_contract_name: str,
    scenario_deploy_value: str | None,
) -> dict[str, Any]:
    """Add an isolated Anvil node and bundled-source gateway."""
    if bool(scenario_contract) == bool(scenario_setup_script):
        raise ValueError("exactly one scenario deployment method is required")
    if not scenario_source_path and not scenario_source_registry:
        raise ValueError("a scenario source path or registry is required")

    services = compose.setdefault("services", {})
    networks = compose.setdefault("networks", {})
    networks[AGENT_NETWORK] = {"internal": True}
    networks[BACKEND_NETWORK] = {"internal": True}

    main = services.setdefault("main", {})
    main["pids_limit"] = 512
    main.setdefault("deploy", {}).setdefault("resources", {}).setdefault(
        "limits", {}
    )["pids"] = 512
    main["cap_drop"] = ["ALL"]
    main["cap_add"] = [
        "CHOWN",
        "DAC_OVERRIDE",
        "KILL",
        "SETGID",
        "SETPCAP",
        "SETUID",
    ]
    main["security_opt"] = ["no-new-privileges:true"]
    main["networks"] = [AGENT_NETWORK]
    # Task images contain the trusted deployment project so the sidecars can
    # initialize state. Hide it from the model container.
    main["tmpfs"] = ["/opt/scenario:rw,noexec,nosuid,size=64k"]
    main.setdefault("depends_on", {})[POLICY_SERVICE] = {
        "condition": "service_healthy"
    }

    anvil_environment = {
        "ANVIL_HOST": "0.0.0.0",
        "RPC_URL": "http://127.0.0.1:8545",
        "CHAIN_MODE": "local",
        "CHAIN_ID": chain_id,
        "ANVIL_HARDFORK": hardfork,
        "SCENARIO_TARGET_ADDRESS": scenario_target_address,
    }
    if scenario_contract:
        anvil_environment["SCENARIO_CONTRACT"] = scenario_contract
    if scenario_setup_script:
        anvil_environment["SCENARIO_SETUP_SCRIPT"] = scenario_setup_script
    if scenario_deploy_value is not None:
        anvil_environment["SCENARIO_DEPLOY_VALUE"] = scenario_deploy_value

    services[ANVIL_SERVICE] = {
        "image": image,
        "user": "10001:10001",
        "cpus": 2.0,
        "mem_limit": "4096m",
        "pids_limit": 256,
        "cap_drop": ["ALL"],
        "security_opt": ["no-new-privileges:true"],
        "entrypoint": [
            "/bin/bash",
            "-lc",
            "start-anvil && exec tail -f /dev/null",
        ],
        "environment": anvil_environment,
        "healthcheck": {
            "test": [
                "CMD-SHELL",
                "cast block-number --rpc-url http://127.0.0.1:8545 >/dev/null",
            ],
            "interval": "1s",
            "timeout": "2s",
            "retries": 120,
        },
        "networks": [BACKEND_NETWORK],
    }

    policy_environment = {
        "EXPLORER_CHAIN_ID": chain_id,
        "INITIAL_BLOCK_NUMBER": "0",
        "RPC_BACKEND_URL": f"http://{ANVIL_SERVICE}:8545",
    }
    if scenario_source_registry:
        policy_environment["LOCAL_SOURCE_REGISTRY_PATH"] = scenario_source_registry
    else:
        policy_environment.update(
            {
                "LOCAL_SOURCE_PATH": scenario_source_path,
                "LOCAL_SOURCE_ADDRESS": scenario_target_address,
                "LOCAL_SOURCE_CONTRACT_NAME": scenario_contract_name,
            }
        )

    services[POLICY_SERVICE] = {
        "image": image,
        "user": "10001:10001",
        "cpus": 2.0,
        "mem_limit": "4096m",
        "pids_limit": 256,
        "cap_drop": ["ALL"],
        "security_opt": ["no-new-privileges:true"],
        "entrypoint": ["python3", "/usr/local/lib/rl-task/policy_gateway.py"],
        "environment": policy_environment,
        "depends_on": {ANVIL_SERVICE: {"condition": "service_healthy"}},
        "healthcheck": {
            "test": [
                "CMD-SHELL",
                "python3 -c \"import urllib.request; "
                "urllib.request.urlopen('http://127.0.0.1:8545/health').read(); "
                "urllib.request.urlopen('http://127.0.0.1:8081/health').read()\"",
            ],
            "interval": "1s",
            "timeout": "2s",
            "retries": 120,
        },
        "networks": [AGENT_NETWORK, BACKEND_NETWORK],
    }
    return compose


class LocalTaskDockerEnvironment(DockerEnvironment):
    """Add local chain sidecars for agents; leave verifier containers alone."""

    def __init__(self, *args: Any, **kwargs: Any):
        self._agent_environment = (
            kwargs.get("agent_install_spec") is not None
            or kwargs.get("network_allowlist") is not None
        )
        super().__init__(*args, **kwargs)

        if not self._agent_environment:
            return

        if self._persistent_env.get("CHAIN_MODE") != "local":
            raise ValueError("this repository accepts only CHAIN_MODE=local")
        self._task_image = self.task_env_config.docker_image or ""
        if not self._task_image:
            raise ValueError("the isolated environment requires a task image")

        self._chain_id = self._persistent_env.get("CHAIN_ID", "1")
        if not self._chain_id.isdigit():
            raise ValueError("CHAIN_ID must be a decimal integer")
        self._hardfork = self._persistent_env.get("ANVIL_HARDFORK", "cancun")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", self._hardfork):
            raise ValueError("ANVIL_HARDFORK is invalid")

        self._scenario_contract = self._persistent_env.get("SCENARIO_CONTRACT")
        self._scenario_setup_script = self._persistent_env.get(
            "SCENARIO_SETUP_SCRIPT"
        )
        if bool(self._scenario_contract) == bool(self._scenario_setup_script):
            raise ValueError("exactly one scenario deployment method is required")

        self._scenario_target_address = self._persistent_env.get(
            "SCENARIO_TARGET_ADDRESS", ""
        )
        if not re.fullmatch(
            r"0x[0-9A-Fa-f]{40}", self._scenario_target_address
        ):
            raise ValueError("SCENARIO_TARGET_ADDRESS is invalid")

        self._scenario_source_path = self._persistent_env.get(
            "SCENARIO_SOURCE_PATH"
        )
        self._scenario_source_registry = self._persistent_env.get(
            "SCENARIO_SOURCE_REGISTRY"
        )
        if self._scenario_source_registry:
            if not self._scenario_source_registry.startswith("/"):
                raise ValueError("SCENARIO_SOURCE_REGISTRY must be absolute")
        elif not self._scenario_source_path or not self._scenario_source_path.startswith(
            "/"
        ):
            raise ValueError("SCENARIO_SOURCE_PATH must be absolute")

        self._scenario_contract_name = self._persistent_env.get(
            "SCENARIO_CONTRACT_NAME", "Scenario"
        )
        if not re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_]*", self._scenario_contract_name
        ):
            raise ValueError("SCENARIO_CONTRACT_NAME is invalid")
        self._scenario_deploy_value = self._persistent_env.get(
            "SCENARIO_DEPLOY_VALUE"
        )

        # Only the local proxy endpoints and a fixed, non-secret compatibility
        # value are visible to model-issued commands.
        for name in tuple(self._persistent_env):
            upper = name.upper()
            if (
                (upper.endswith("_RPC_URL") and upper != "RPC_URL")
                or upper.startswith(("ARCHIVE_", "FORK_", "RL_TASK_POLICY_"))
                or upper.startswith("SCENARIO_")
                or (upper.endswith("_API_KEY") and upper != "ETHERSCAN_API_KEY")
            ):
                self._persistent_env.pop(name, None)
        self._persistent_env.update(
            {
                "RPC_URL": f"http://{POLICY_SERVICE}:8545",
                "EXPLORER_API_URL": f"http://{POLICY_SERVICE}:8081/api",
                "ETHERSCAN_API_KEY": "source-only",
            }
        )

    def _prepare_egress_proxy_compose(self) -> None:
        if not self._agent_environment:
            super()._prepare_egress_proxy_compose()
            return

        super()._prepare_egress_proxy_compose()
        path = self._egress_proxy_compose_path
        if path is not None and path.exists():
            compose = json.loads(path.read_text())
        else:
            path = self.trial_paths.trial_dir / "docker-compose-policy.json"
            self._egress_proxy_compose_path = path
            compose = {}

        add_local_services(
            compose,
            image=self._task_image,
            chain_id=self._chain_id,
            hardfork=self._hardfork,
            scenario_contract=self._scenario_contract,
            scenario_setup_script=self._scenario_setup_script,
            scenario_target_address=self._scenario_target_address,
            scenario_source_path=self._scenario_source_path,
            scenario_source_registry=self._scenario_source_registry,
            scenario_contract_name=self._scenario_contract_name,
            scenario_deploy_value=self._scenario_deploy_value,
        )
        path.write_text(json.dumps(compose, indent=2))
        path.chmod(0o600)

    def agent_process_env(
        self, env: dict[str, str] | None
    ) -> dict[str, str] | None:
        merged = super().agent_process_env(env)
        if not self._agent_environment:
            return merged
        result = dict(merged or {})
        bypass = {"localhost", "127.0.0.1", POLICY_SERVICE}
        for key in ("NO_PROXY", "no_proxy"):
            bypass.update(part.strip() for part in result.get(key, "").split(","))
            result[key] = ",".join(sorted(part for part in bypass if part))
        return result

    async def _run_docker_compose_command(
        self,
        command: list[str],
        check: bool = True,
        timeout_sec: int | None = None,
    ):
        # Pier normally passes ``--rmi all`` when deleting a trial. The local
        # Anvil and source gateway reuse the task image, so deleting it races
        # with other trials that are starting from the same image.
        return await super()._run_docker_compose_command(
            preserve_shared_images(command),
            check=check,
            timeout_sec=timeout_sec,
        )
