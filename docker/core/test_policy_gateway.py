from __future__ import annotations

import json
import pathlib
import tempfile
import unittest
from unittest import mock

from policy_gateway import (
    PolicyError,
    RpcPolicy,
    local_source_response,
    load_local_source_registry,
    safe_backend_error,
    validate_source_query,
)


FORK_BLOCK = 25_541_000
FUTURE_BLOCK = 25_541_217
FUTURE_HASH = "0x" + "ab" * 32
LOCAL_HASH = "0x" + "cd" * 32
OLD_HASH = "0x" + "ef" * 32


class FakeBackend:
    def __init__(self):
        self.current = FORK_BLOCK
        self.calls: list[tuple[str, object]] = []
        self.transactions = {
            FUTURE_HASH: {
                "hash": FUTURE_HASH,
                "blockNumber": hex(FUTURE_BLOCK),
                "blockHash": "0x" + "11" * 32,
            },
            OLD_HASH: {
                "hash": OLD_HASH,
                "blockNumber": hex(FORK_BLOCK - 1),
                "blockHash": "0x" + "22" * 32,
            },
            LOCAL_HASH: {
                "hash": LOCAL_HASH,
                "blockNumber": hex(FORK_BLOCK + 1),
                "blockHash": "0x" + "33" * 32,
            },
        }

    def request(self, method, params):
        self.calls.append((method, params))
        if method == "eth_blockNumber":
            return hex(self.current)
        if method == "eth_getTransactionByHash":
            return self.transactions.get(params[0])
        if method == "eth_getTransactionReceipt":
            return self.transactions.get(params[0])
        if method == "eth_getRawTransactionByHash":
            return "0x1234"
        if method == "eth_getBlockByNumber":
            number = self.current if params[0] in {"latest", "pending"} else int(params[0], 16)
            if number > self.current:
                return None
            block_hash = "0x" + "33" * 32 if number == FORK_BLOCK + 1 else "0x" + "22" * 32
            tx_hash = LOCAL_HASH if number == FORK_BLOCK + 1 else OLD_HASH
            transactions = (
                [self.transactions[tx_hash]]
                if len(params) > 1 and params[1]
                else [tx_hash]
            )
            return {
                "number": hex(number),
                "hash": block_hash,
                "transactions": transactions,
            }
        if method == "eth_getBlockByHash":
            for number, block_hash in (
                (FORK_BLOCK - 1, "0x" + "22" * 32),
                (FORK_BLOCK + 1, "0x" + "33" * 32),
            ):
                if params[0].lower() == block_hash:
                    return {"number": hex(number), "hash": block_hash}
            return None
        if method in {"eth_sendRawTransaction", "eth_sendTransaction"}:
            self.current = FORK_BLOCK + 1
            return LOCAL_HASH
        if method == "eth_getBlockReceipts":
            return [
                {
                    "transactionHash": transaction["hash"],
                    "blockNumber": transaction["blockNumber"],
                    "blockHash": transaction["blockHash"],
                }
                for transaction in self.transactions.values()
            ]
        if method in {
            "eth_getRawTransactionByBlockNumberAndIndex",
            "eth_getRawTransactionByBlockHashAndIndex",
        }:
            return "0x1234"
        if method in {
            "eth_getTransactionByBlockNumberAndIndex",
            "eth_getTransactionByBlockHashAndIndex",
        }:
            return self.transactions[OLD_HASH]
        if method == "eth_getLogs":
            return []
        return "ok"


def request(method, params=None, request_id=1):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": [] if params is None else params,
    }


class SourcePolicyTests(unittest.TestCase):
    def test_local_source_response_matches_etherscan_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Scenario.sol"
            path.write_text("pragma solidity ^0.8.28; contract Scenario {}")
            body = json.loads(local_source_response(str(path), "Scenario"))
        self.assertEqual(body["status"], "1")
        self.assertEqual(body["result"][0]["ContractName"], "Scenario")
        self.assertIn("contract Scenario", body["result"][0]["SourceCode"])

    def test_local_source_response_can_return_a_standard_json_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            primary = root / "Primary.sol"
            dependency = root / "Dependency.sol"
            primary.write_text(
                'pragma solidity ^0.8.28; import "./Dependency.sol"; contract Primary {}'
            )
            dependency.write_text(
                "pragma solidity ^0.8.28; contract Dependency {}"
            )
            body = json.loads(
                local_source_response(
                    str(primary),
                    "Primary",
                    {
                        "Primary.sol": str(primary),
                        "Dependency.sol": str(dependency),
                    },
                )
            )
        standard_input = json.loads(body["result"][0]["SourceCode"])
        self.assertEqual(standard_input["language"], "Solidity")
        self.assertIn("Primary.sol", standard_input["sources"])
        self.assertIn("Dependency.sol", standard_input["sources"])

    def test_local_source_registry_maps_separate_contracts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "Module.sol"
            source.write_text("pragma solidity ^0.8.28; contract Module {}")
            registry = root / "registry.json"
            address = "0x" + "12" * 20
            registry.write_text(
                json.dumps({address: {"path": str(source), "name": "Module"}})
            )
            # Registry paths are deliberately confined to the trusted scenario
            # tree in production. Exercise validation by using that prefix in
            # a temporary symlink-free path only through a patched value.
            decoded = json.loads(registry.read_text())
            decoded[address]["path"] = "/opt/scenario/src/Module.sol"
            decoded[address]["sources"] = {
                "Module.sol": "/opt/scenario/src/Module.sol"
            }
            registry.write_text(json.dumps(decoded))
            with mock.patch.object(pathlib.Path, "is_file", return_value=True):
                loaded = load_local_source_registry(str(registry))
        self.assertEqual(loaded[address.lower()][1], "Module")
        self.assertIn("Module.sol", loaded[address.lower()][2])

    def test_backend_errors_redact_credential_urls(self):
        message = (
            "execution reverted while fetching "
            "https://node.invalid/v2/archive-secret?apikey=key-secret"
        )
        result = safe_backend_error(message)
        self.assertIn("execution reverted", result)
        self.assertNotIn("archive-secret", result)
        self.assertNotIn("key-secret", result)

    def test_only_getsourcecode_is_accepted(self):
        address = "0x" + "12" * 20
        self.assertEqual(
            validate_source_query(
                f"/api?module=contract&action=getsourcecode&address={address}&apikey=dummy"
            ),
            address,
        )

    def test_transaction_history_is_rejected(self):
        address = "0x" + "12" * 20
        with self.assertRaises(PolicyError):
            validate_source_query(
                f"/api?module=account&action=tokentx&address={address}&apikey=dummy"
            )

    def test_proxy_receipt_is_rejected(self):
        with self.assertRaises(PolicyError):
            validate_source_query(
                f"/api?module=proxy&action=eth_getTransactionReceipt&txhash={FUTURE_HASH}"
            )

    def test_chain_specific_source_query(self):
        address = "0x" + "12" * 20
        self.assertEqual(
            validate_source_query(
                f"/api?chainid=8453&module=contract&action=getsourcecode&address={address}",
                "8453",
            ),
            address,
        )
        with self.assertRaises(PolicyError):
            validate_source_query(
                f"/api?chainid=1&module=contract&action=getsourcecode&address={address}",
                "8453",
            )


class RpcPolicyTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.policy = RpcPolicy(self.backend, FORK_BLOCK)

    def test_future_transaction_lookup_returns_null(self):
        response = self.policy.handle(request("eth_getTransactionByHash", [FUTURE_HASH]))
        self.assertIsNone(response["result"])

    def test_prefork_transaction_lookup_is_allowed(self):
        response = self.policy.handle(request("eth_getTransactionByHash", [OLD_HASH]))
        self.assertEqual(response["result"]["hash"], OLD_HASH)

    def test_future_raw_transaction_lookup_returns_null(self):
        response = self.policy.handle(request("eth_getRawTransactionByHash", [FUTURE_HASH]))
        self.assertIsNone(response["result"])

    def test_locally_submitted_transaction_remains_visible(self):
        sent = self.policy.handle(request("eth_sendRawTransaction", ["0x1234"]))
        self.assertEqual(sent["result"], LOCAL_HASH)
        looked_up = self.policy.handle(request("eth_getTransactionByHash", [LOCAL_HASH]))
        self.assertEqual(looked_up["result"]["hash"], LOCAL_HASH)

    def test_future_block_is_not_forwarded(self):
        response = self.policy.handle(
            request("eth_getBlockByNumber", [hex(FUTURE_BLOCK), False])
        )
        self.assertIsNone(response["result"])

    def test_consensus_head_aliases_are_not_forwarded(self):
        for alias in ("safe", "finalized"):
            with self.subTest(alias=alias):
                before = len(self.backend.calls)
                response = self.policy.handle(
                    request("eth_getBlockByNumber", [alias, False])
                )
                self.assertIsNone(response["result"])
                self.assertEqual(len(self.backend.calls), before)

    def test_future_transaction_trace_is_denied(self):
        response = self.policy.handle(
            request("debug_traceTransaction", [FUTURE_HASH, {}])
        )
        self.assertEqual(response["error"]["code"], -32004)

    def test_prefork_block_receipts_by_hash_are_allowed(self):
        response = self.policy.handle(
            request("eth_getBlockReceipts", ["0x" + "22" * 32])
        )
        self.assertEqual(len(response["result"]), 3)

    def test_anvil_reset_is_denied(self):
        response = self.policy.handle(request("anvil_reset", []))
        self.assertEqual(response["error"]["code"], -32004)

    def test_log_filter_at_fork_is_allowed(self):
        response = self.policy.handle(
            request(
                "eth_getLogs",
                [{"fromBlock": hex(FORK_BLOCK - 10), "toBlock": "latest"}],
            )
        )
        self.assertEqual(response["result"], [])

    def test_unbounded_log_scan_is_denied(self):
        response = self.policy.handle(
            request(
                "eth_getLogs",
                [{"fromBlock": "earliest", "toBlock": "latest"}],
            )
        )
        self.assertEqual(response["error"]["code"], -32602)

    def test_large_fee_history_is_denied(self):
        response = self.policy.handle(
            request("eth_feeHistory", [hex(8_193), "latest", []])
        )
        self.assertEqual(response["error"]["code"], -32602)


class HiddenPrestatePolicyTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.policy = RpcPolicy(
            self.backend,
            FORK_BLOCK,
            hide_prestate_history=True,
        )

    def test_setup_transaction_and_receipt_are_hidden_without_backend_lookup(self):
        before = len(self.backend.calls)
        transaction = self.policy.handle(
            request("eth_getTransactionByHash", [OLD_HASH])
        )
        receipt = self.policy.handle(
            request("eth_getTransactionReceipt", [OLD_HASH])
        )
        self.assertIsNone(transaction["result"])
        self.assertIsNone(receipt["result"])
        self.assertEqual(len(self.backend.calls), before)

    def test_setup_raw_transaction_and_trace_are_hidden(self):
        raw = self.policy.handle(
            request("eth_getRawTransactionByHash", [OLD_HASH])
        )
        trace = self.policy.handle(
            request("debug_traceTransaction", [OLD_HASH, {}])
        )
        self.assertIsNone(raw["result"])
        self.assertEqual(trace["error"]["code"], -32004)

    def test_full_prestate_block_is_reduced_to_transaction_hashes(self):
        response = self.policy.handle(
            request("eth_getBlockByNumber", ["latest", True])
        )
        self.assertEqual(response["result"]["transactions"], [OLD_HASH])
        self.assertEqual(
            self.backend.calls[-1],
            ("eth_getBlockByNumber", ["latest", False]),
        )

    def test_prestate_block_index_and_block_trace_are_hidden(self):
        transaction = self.policy.handle(
            request(
                "eth_getTransactionByBlockNumberAndIndex",
                [hex(FORK_BLOCK), "0x0"],
            )
        )
        trace = self.policy.handle(
            request("debug_traceBlockByNumber", [hex(FORK_BLOCK), {}])
        )
        self.assertIsNone(transaction["result"])
        self.assertEqual(trace["error"]["code"], -32004)

    def test_prestate_block_receipts_are_empty(self):
        response = self.policy.handle(
            request("eth_getBlockReceipts", [hex(FORK_BLOCK)])
        )
        self.assertEqual(response["result"], [])

    def test_historical_state_before_initialized_head_is_hidden(self):
        response = self.policy.handle(
            request("eth_getBalance", ["0x" + "12" * 20, hex(FORK_BLOCK - 1)])
        )
        self.assertEqual(response["error"]["code"], -32004)
        self.assertIn("pre-state history", response["error"]["message"])

    def test_current_state_and_setup_logs_remain_available(self):
        state = self.policy.handle(
            request("eth_getBalance", ["0x" + "12" * 20, "latest"])
        )
        logs = self.policy.handle(
            request(
                "eth_getLogs",
                [
                    {
                        "address": "0x" + "12" * 20,
                        "fromBlock": hex(FORK_BLOCK - 10),
                        "toBlock": "latest",
                    }
                ],
            )
        )
        self.assertEqual(state["result"], "ok")
        self.assertEqual(logs["result"], [])

    def test_global_setup_log_enumeration_is_denied(self):
        response = self.policy.handle(
            request(
                "eth_getLogs",
                [{"fromBlock": hex(FORK_BLOCK - 10), "toBlock": "latest"}],
            )
        )
        self.assertEqual(response["error"]["code"], -32602)
        self.assertIn("contract addresses", response["error"]["message"])

    def test_locally_submitted_transaction_is_fully_visible(self):
        sent = self.policy.handle(request("eth_sendRawTransaction", ["0x1234"]))
        self.assertEqual(sent["result"], LOCAL_HASH)
        transaction = self.policy.handle(
            request("eth_getTransactionByHash", [LOCAL_HASH])
        )
        receipt = self.policy.handle(
            request("eth_getTransactionReceipt", [LOCAL_HASH])
        )
        block = self.policy.handle(
            request("eth_getBlockByNumber", ["latest", True])
        )
        self.assertEqual(transaction["result"]["hash"], LOCAL_HASH)
        self.assertEqual(receipt["result"]["hash"], LOCAL_HASH)
        self.assertEqual(block["result"]["transactions"][0]["hash"], LOCAL_HASH)
        self.assertEqual(
            self.backend.calls[-1],
            ("eth_getBlockByNumber", ["latest", True]),
        )

    def test_trace_filter_cannot_cover_setup_blocks(self):
        response = self.policy.handle(
            request(
                "trace_filter",
                [{"fromBlock": hex(FORK_BLOCK), "toBlock": "latest"}],
            )
        )
        self.assertEqual(response["error"]["code"], -32004)


if __name__ == "__main__":
    unittest.main()
