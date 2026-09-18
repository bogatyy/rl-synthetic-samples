from __future__ import annotations

import unittest

from runner.local_environment import (
    AGENT_NETWORK,
    ANVIL_SERVICE,
    BACKEND_NETWORK,
    POLICY_SERVICE,
    add_local_services,
    preserve_shared_images,
)


def local_compose() -> dict:
    return add_local_services(
        {},
        image="task-image",
        chain_id="1",
        hardfork="cancun",
        scenario_contract=None,
        scenario_setup_script="script/Setup.s.sol:Setup",
        scenario_target_address="0x" + "12" * 20,
        scenario_source_path=None,
        scenario_source_registry="/opt/scenario/source-registry.json",
        scenario_contract_name="Scenario",
        scenario_deploy_value=None,
    )


class ComposePolicyTests(unittest.TestCase):
    def test_trial_cleanup_preserves_shared_task_images(self):
        self.assertEqual(
            preserve_shared_images(
                ["down", "--rmi", "all", "--volumes", "--remove-orphans"]
            ),
            ["down", "--volumes", "--remove-orphans"],
        )
        self.assertEqual(
            preserve_shared_images(["down", "--remove-orphans"]),
            ["down", "--remove-orphans"],
        )

    def test_services_are_airgapped_and_separated(self):
        compose = local_compose()
        services = compose["services"]
        self.assertEqual(compose["networks"][AGENT_NETWORK], {"internal": True})
        self.assertEqual(compose["networks"][BACKEND_NETWORK], {"internal": True})
        self.assertEqual(services["main"]["networks"], [AGENT_NETWORK])
        self.assertEqual(services[ANVIL_SERVICE]["networks"], [BACKEND_NETWORK])
        self.assertEqual(
            services[POLICY_SERVICE]["networks"], [AGENT_NETWORK, BACKEND_NETWORK]
        )
        self.assertNotIn("default", str(compose["services"]))

    def test_policy_waits_for_completed_scenario_setup(self):
        services = local_compose()["services"]
        anvil_health = " ".join(services[ANVIL_SERVICE]["healthcheck"]["test"])
        self.assertIn("/tmp/rl-task-scenario.ready", anvil_health)
        self.assertIn("$$SCENARIO_TARGET_ADDRESS", anvil_health)
        self.assertEqual(
            services[POLICY_SERVICE]["depends_on"],
            {ANVIL_SERVICE: {"condition": "service_healthy"}},
        )
        self.assertEqual(
            services["main"]["depends_on"],
            {POLICY_SERVICE: {"condition": "service_healthy"}},
        )

    def test_no_external_chain_credentials_exist(self):
        compose = local_compose()
        rendered = str(compose).upper()
        self.assertNotIn("ARCHIVE", rendered)
        self.assertNotIn("ALCHEMY", rendered)
        self.assertNotIn("ETHERSCAN_API_KEY", rendered)
        self.assertNotIn("FORK_BLOCK_NUMBER", rendered)
        self.assertEqual(
            compose["services"][POLICY_SERVICE]["environment"][
                "INITIAL_BLOCK_NUMBER"
            ],
            "0",
        )

    def test_containers_are_unprivileged(self):
        services = local_compose()["services"]
        for service_name in (ANVIL_SERVICE, POLICY_SERVICE):
            service = services[service_name]
            self.assertEqual(service["user"], "10001:10001")
            self.assertEqual(service["cpus"], 2.0)
            self.assertEqual(service["mem_limit"], "4096m")
            self.assertEqual(service["pids_limit"], 256)
            self.assertEqual(service["cap_drop"], ["ALL"])
            self.assertEqual(service["security_opt"], ["no-new-privileges:true"])

    def test_main_security_boundary_overrides_defaults(self):
        compose = {
            "services": {
                "main": {
                    "pids_limit": 4096,
                    "cap_drop": [],
                    "cap_add": ["ALL"],
                    "security_opt": [],
                    "networks": ["default", BACKEND_NETWORK],
                }
            }
        }
        add_local_services(
            compose,
            image="task-image",
            chain_id="1",
            hardfork="cancun",
            scenario_contract="src/Scenario.sol:Scenario",
            scenario_setup_script=None,
            scenario_target_address="0x" + "12" * 20,
            scenario_source_path="/opt/scenario/src/Scenario.sol",
            scenario_source_registry=None,
            scenario_contract_name="Scenario",
            scenario_deploy_value="1ether",
        )
        main = compose["services"]["main"]
        self.assertEqual(main["pids_limit"], 512)
        self.assertEqual(main["deploy"]["resources"]["limits"]["pids"], 512)
        self.assertEqual(main["cap_drop"], ["ALL"])
        self.assertEqual(
            main["cap_add"],
            ["CHOWN", "DAC_OVERRIDE", "KILL", "SETGID", "SETPCAP", "SETUID"],
        )
        self.assertEqual(main["security_opt"], ["no-new-privileges:true"])
        self.assertEqual(main["networks"], [AGENT_NETWORK])
        self.assertEqual(
            main["tmpfs"], ["/opt/scenario:rw,noexec,nosuid,size=64k"]
        )


if __name__ == "__main__":
    unittest.main()
