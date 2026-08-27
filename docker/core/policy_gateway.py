#!/usr/bin/env python3
"""Bundled-source and bounded JSON-RPC gateway for local task chains.

This process runs in a sidecar that the agent cannot inspect. The agent can
reach its two HTTP listeners, but not the trusted Anvil service behind it.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}\Z")
HASH_RE = re.compile(r"0x[0-9a-fA-F]{64}\Z")
URL_RE = re.compile(r"(?i)\b(?:https?|wss?)://[^\s\"'<>]+")
API_KEY_RE = re.compile(r"(?i)(apikey=)[^&\s\"'<>]+")
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_RPC_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_SOURCE_BYTES = 32 * 1024 * 1024
MAX_BATCH_REQUESTS = 32
MAX_RPC_CALLS = 25_000
MAX_BLOCK_RANGE = 100_000
MAX_FEE_HISTORY_BLOCKS = 8_192
MAX_BACKEND_CONCURRENCY = 16
MAX_LOG_ADDRESSES = 64


class PolicyError(Exception):
    def __init__(self, message: str, code: int = -32004):
        super().__init__(message)
        self.code = code
        self.message = message


def safe_backend_error(message: Any) -> str:
    """Keep useful revert text while removing unexpected URLs or API keys."""
    text = str(message)[:4_096]
    text = URL_RE.sub("<redacted-url>", text)
    return API_KEY_RE.sub(r"\1<redacted>", text)


def _hex_number(value: Any) -> int | None:
    if not isinstance(value, str) or not value.startswith("0x"):
        return None
    try:
        return int(value, 16)
    except ValueError:
        return None


def validate_source_query(path: str, chain_id: str = "1") -> str:
    parsed = urllib.parse.urlsplit(path)
    if parsed.path not in {"/api", "/v2/api"}:
        raise PolicyError("only the local source endpoint is available")

    query = urllib.parse.parse_qs(
        parsed.query, keep_blank_values=True, strict_parsing=True
    )
    allowed = {"module", "action", "address", "apikey", "chainid"}
    if set(query) - allowed or any(len(values) != 1 for values in query.values()):
        raise PolicyError("unsupported explorer query")
    if query.get("module") != ["contract"] or query.get("action") != [
        "getsourcecode"
    ]:
        raise PolicyError("only contract/getsourcecode is available")
    if "chainid" in query and query["chainid"] != [chain_id]:
        raise PolicyError("source query is for the wrong chain")
    address = query.get("address", [""])[0]
    if not ADDRESS_RE.fullmatch(address):
        raise PolicyError("invalid contract address")
    return address


def local_source_response(
    path: str,
    contract_name: str,
    sources: dict[str, str] | None = None,
) -> bytes:
    source_path = pathlib.Path(path)
    source = source_path.read_text(encoding="utf-8")
    source_bytes = len(source.encode())
    source_code = source
    if sources:
        source_entries = {}
        for logical_name, bundled_path in sources.items():
            content = pathlib.Path(bundled_path).read_text(encoding="utf-8")
            source_bytes += len(content.encode())
            source_entries[logical_name] = {"content": content}
        source_code = json.dumps(
            {
                "language": "Solidity",
                "sources": source_entries,
                "settings": {
                    "optimizer": {"enabled": False, "runs": 0},
                    "evmVersion": "cancun",
                },
            },
            separators=(",", ":"),
        )
    if source_bytes > MAX_SOURCE_BYTES:
        raise PolicyError("local source response too large")
    body = json.dumps(
        {
            "status": "1",
            "message": "OK",
            "result": [
                {
                    "SourceCode": source_code,
                    "ABI": "[]",
                    "ContractName": contract_name,
                    "CompilerVersion": "v0.8.28+commit.7893614a",
                    "OptimizationUsed": "1",
                    "Runs": "200",
                    "ConstructorArguments": "",
                    "EVMVersion": "cancun",
                    "Library": "",
                    "LicenseType": "MIT",
                    "Proxy": "0",
                    "Implementation": "",
                    "SwarmSource": "",
                }
            ],
        },
        separators=(",", ":"),
    ).encode()
    if len(body) > MAX_SOURCE_BYTES:
        raise PolicyError("local source response too large")
    return body


def load_local_source_registry(
    path: str,
) -> dict[str, tuple[str, str, dict[str, str] | None]]:
    """Load an address -> (source path, contract name, source bundle) registry.

    The registry lives in the trusted task image.  It lets a local scenario
    expose separately verified contracts without copying its deployment
    project into the model container.
    """
    registry_path = pathlib.Path(path)
    decoded = json.loads(registry_path.read_text(encoding="utf-8"))
    if not isinstance(decoded, dict) or not decoded:
        raise ValueError("local source registry must be a non-empty object")
    result: dict[str, tuple[str, str, dict[str, str] | None]] = {}
    for address, entry in decoded.items():
        if not isinstance(address, str) or not ADDRESS_RE.fullmatch(address):
            raise ValueError("local source registry contains an invalid address")
        if not isinstance(entry, dict):
            raise ValueError("local source registry entry must be an object")
        source_path = entry.get("path")
        contract_name = entry.get("name")
        sources = entry.get("sources")
        if (
            not isinstance(source_path, str)
            or not source_path.startswith("/opt/scenario/")
            or not isinstance(contract_name, str)
            or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", contract_name)
        ):
            raise ValueError("local source registry entry is invalid")
        if not pathlib.Path(source_path).is_file():
            raise ValueError("local source registry references a missing file")
        source_bundle = None
        if sources is not None:
            if not isinstance(sources, dict) or not sources:
                raise ValueError("local source bundle must be a non-empty object")
            source_bundle = {}
            for logical_name, bundled_path in sources.items():
                if (
                    not isinstance(logical_name, str)
                    or not re.fullmatch(r"[A-Za-z0-9_./-]+\.sol", logical_name)
                    or not isinstance(bundled_path, str)
                    or not bundled_path.startswith("/opt/scenario/src/")
                    or not pathlib.Path(bundled_path).is_file()
                ):
                    raise ValueError("local source bundle entry is invalid")
                source_bundle[logical_name] = bundled_path
        result[address.lower()] = (source_path, contract_name, source_bundle)
    return result


class Backend:
    def __init__(self, url: str):
        self.url = url
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self._next_id = 1
        self._id_lock = threading.Lock()
        self._semaphore = threading.BoundedSemaphore(MAX_BACKEND_CONCURRENCY)

    def _id(self) -> int:
        with self._id_lock:
            value = self._next_id
            self._next_id += 1
            return value

    def request(self, method: str, params: list[Any] | dict[str, Any]) -> Any:
        payload = {
            "jsonrpc": "2.0",
            "id": self._id(),
            "method": method,
            "params": params,
        }
        data = json.dumps(payload, separators=(",", ":")).encode()
        request = urllib.request.Request(
            self.url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self._semaphore:
            with self._opener.open(request, timeout=60) as response:
                body = response.read(MAX_RPC_RESPONSE_BYTES + 1)
        if len(body) > MAX_RPC_RESPONSE_BYTES:
            raise PolicyError("backend response too large")
        decoded = json.loads(body)
        if not isinstance(decoded, dict):
            raise PolicyError("invalid backend response")
        if "error" in decoded:
            error = decoded["error"] if isinstance(decoded["error"], dict) else {}
            raise PolicyError(
                safe_backend_error(error.get("message", "backend RPC error")),
                int(error.get("code", -32000)),
            )
        return decoded.get("result")


class RpcPolicy:
    """Allow ordinary chain work while denying node-control escape hatches."""

    SIMPLE_METHODS = {
        "eth_accounts",
        "eth_blobBaseFee",
        "eth_blockNumber",
        "eth_chainId",
        "eth_coinbase",
        "eth_gasPrice",
        "eth_getFilterChanges",
        "eth_getFilterLogs",
        "eth_getWork",
        "eth_hashrate",
        "eth_maxPriorityFeePerGas",
        "eth_mining",
        "eth_newBlockFilter",
        "eth_newPendingTransactionFilter",
        "eth_protocolVersion",
        "eth_sign",
        "eth_signTransaction",
        "eth_signTypedData",
        "eth_signTypedData_v3",
        "eth_signTypedData_v4",
        "eth_syncing",
        "eth_uninstallFilter",
        "net_listening",
        "net_peerCount",
        "net_version",
        "rpc_modules",
        "web3_clientVersion",
        "web3_sha3",
    }

    BLOCK_REF_METHODS = {
        "debug_traceCall": 1,
        "eth_call": 1,
        "eth_createAccessList": 1,
        "eth_estimateGas": 1,
        "eth_getBalance": 1,
        "eth_getCode": 1,
        "eth_getProof": 2,
        "eth_getStorageAt": 2,
        "eth_getTransactionCount": 1,
        "trace_call": 2,
    }

    BLOCK_NUMBER_METHODS = {
        "debug_traceBlockByNumber": 0,
        "eth_getBlockTransactionCountByNumber": 0,
        "eth_getRawTransactionByBlockNumberAndIndex": 0,
        "eth_getTransactionByBlockNumberAndIndex": 0,
        "eth_getUncleByBlockNumberAndIndex": 0,
        "eth_getUncleCountByBlockNumber": 0,
        "trace_block": 0,
        "trace_replayBlockTransactions": 0,
    }

    BLOCK_HASH_METHODS = {
        "debug_traceBlockByHash": 0,
        "eth_getBlockTransactionCountByHash": 0,
        "eth_getRawTransactionByBlockHashAndIndex": 0,
        "eth_getTransactionByBlockHashAndIndex": 0,
        "eth_getUncleByBlockHashAndIndex": 0,
        "eth_getUncleCountByBlockHash": 0,
    }

    TX_LOOKUP_METHODS = {
        "eth_getTransactionByHash",
        "eth_getTransactionReceipt",
    }
    RAW_TX_LOOKUP_METHODS = {"eth_getRawTransactionByHash"}
    TX_TRACE_METHODS = {
        "debug_traceTransaction",
        "trace_replayTransaction",
        "trace_transaction",
    }
    SEND_METHODS = {"eth_sendRawTransaction", "eth_sendTransaction"}

    # These methods reveal transaction bodies or execution traces by walking a
    # block instead of naming a transaction hash.  Local scenarios are built
    # with ordinary setup transactions, but that authoring trace is not part
    # of the audit surface.
    BLOCK_NUMBER_HISTORY_METHODS = {
        "debug_traceBlockByNumber",
        "eth_getRawTransactionByBlockNumberAndIndex",
        "eth_getTransactionByBlockNumberAndIndex",
        "trace_block",
        "trace_replayBlockTransactions",
    }
    BLOCK_HASH_HISTORY_METHODS = {
        "debug_traceBlockByHash",
        "eth_getRawTransactionByBlockHashAndIndex",
        "eth_getTransactionByBlockHashAndIndex",
    }

    def __init__(
        self,
        backend: Backend,
        initial_block: int,
        *,
        hide_prestate_history: bool = False,
    ):
        self.backend = backend
        self.initial_block = initial_block
        self.hide_prestate_history = hide_prestate_history
        self.local_transactions: set[str] = set()
        self._local_lock = threading.Lock()
        self._request_count = 0
        self._request_lock = threading.Lock()
        # The policy sidecar starts only after scenario setup is complete.
        # This boundary separates author-created pre-state from blocks mined by
        # the model during its own attempt.
        self.prestate_block = self._current_block() if hide_prestate_history else None

    def _current_block(self) -> int:
        value = _hex_number(self.backend.request("eth_blockNumber", []))
        if value is None:
            raise PolicyError("invalid block number from backend")
        return value

    def _canonical_block_hash(self, number: int) -> str | None:
        block = self.backend.request("eth_getBlockByNumber", [hex(number), False])
        if not isinstance(block, dict):
            return None
        value = block.get("hash")
        return value.lower() if isinstance(value, str) else None

    def _block_hash_allowed(self, value: Any) -> bool:
        if not isinstance(value, str) or not HASH_RE.fullmatch(value):
            return False
        block = self.backend.request("eth_getBlockByHash", [value, False])
        if not isinstance(block, dict):
            return False
        number = _hex_number(block.get("number"))
        if number is None:
            return False
        if number <= self.initial_block:
            return True
        if number > self._current_block():
            return False
        return self._canonical_block_hash(number) == value.lower()

    def _block_ref_allowed(self, value: Any) -> bool:
        if value is None or value in {"earliest", "latest", "pending"}:
            return True
        if isinstance(value, dict):
            if "blockHash" in value:
                return self._block_hash_allowed(value["blockHash"])
            value = value.get("blockNumber")
        number = _hex_number(value)
        return number is not None and number <= self._current_block()

    def _require_block_ref(self, value: Any) -> None:
        if not self._block_ref_allowed(value):
            raise PolicyError("block is outside the local task history")

    def _require_visible_state_ref(self, value: Any) -> None:
        self._require_block_ref(value)
        if (
            self.prestate_block is not None
            and self._block_ref_number(value) < self.prestate_block
        ):
            raise PolicyError("pre-state history is unavailable")

    def _block_ref_number(self, value: Any) -> int:
        if value is None or value in {"latest", "pending"}:
            return self._current_block()
        if value == "earliest":
            return 0
        if isinstance(value, dict):
            if "blockHash" in value:
                block = self.backend.request(
                    "eth_getBlockByHash", [value["blockHash"], False]
                )
                number = _hex_number(block.get("number")) if isinstance(block, dict) else None
                if number is None:
                    raise PolicyError("invalid block reference", -32602)
                return number
            value = value.get("blockNumber")
        number = _hex_number(value)
        if number is None:
            raise PolicyError("invalid block reference", -32602)
        return number

    def _require_bounded_range(self, first: Any, last: Any) -> None:
        self._require_block_ref(first)
        self._require_block_ref(last)
        first_number = self._block_ref_number(first)
        last_number = self._block_ref_number(last)
        if last_number < first_number or last_number - first_number > MAX_BLOCK_RANGE:
            raise PolicyError("block range is too large", -32602)

    def _block_identifier_number(self, value: Any) -> int:
        if isinstance(value, str) and HASH_RE.fullmatch(value):
            block = self.backend.request("eth_getBlockByHash", [value, False])
            number = _hex_number(block.get("number")) if isinstance(block, dict) else None
            if number is None:
                raise PolicyError("invalid block reference", -32602)
            return number
        return self._block_ref_number(value)

    def _prestate_block(self, value: Any) -> bool:
        return (
            self.prestate_block is not None
            and self._block_identifier_number(value) <= self.prestate_block
        )

    def _block_params_without_prestate_bodies(
        self, params: list[Any] | dict[str, Any], block_ref: Any
    ) -> list[Any] | dict[str, Any]:
        if not self._prestate_block(block_ref):
            return params
        if not isinstance(params, list):
            raise PolicyError("positional JSON-RPC params required", -32602)
        filtered = list(params)
        if len(filtered) < 2:
            filtered.append(False)
        else:
            filtered[1] = False
        return filtered

    def _filter_block_receipts(self, result: Any) -> list[Any]:
        if not isinstance(result, list):
            raise PolicyError("invalid backend block receipts")
        filtered = []
        for receipt in result:
            tx_hash = receipt.get("transactionHash") if isinstance(receipt, dict) else None
            if isinstance(tx_hash, str) and self._transaction_allowed(tx_hash):
                filtered.append(receipt)
        return filtered

    def _require_local_log_scope(self, query: dict[str, Any]) -> None:
        if not self.hide_prestate_history:
            return
        addresses = query.get("address")
        if isinstance(addresses, str):
            addresses = [addresses]
        if (
            not isinstance(addresses, list)
            or not addresses
            or len(addresses) > MAX_LOG_ADDRESSES
            or not all(
                isinstance(address, str) and ADDRESS_RE.fullmatch(address)
                for address in addresses
            )
        ):
            raise PolicyError(
                "local log queries require one or more contract addresses",
                -32602,
            )

    def _transaction_allowed(self, tx_hash: str, result: Any | None = None) -> bool:
        if not isinstance(tx_hash, str) or not HASH_RE.fullmatch(tx_hash):
            return False
        lowered = tx_hash.lower()
        with self._local_lock:
            if lowered in self.local_transactions:
                return True
        if self.hide_prestate_history:
            return False
        tx = (
            result
            if isinstance(result, dict) and "blockNumber" in result
            else self.backend.request("eth_getTransactionByHash", [tx_hash])
        )
        if not isinstance(tx, dict):
            return False
        number = _hex_number(tx.get("blockNumber"))
        if number is None:
            return False
        if number <= self.initial_block:
            return True
        block_hash = tx.get("blockHash")
        if not isinstance(block_hash, str) or number > self._current_block():
            return False
        return self._canonical_block_hash(number) == block_hash.lower()

    def _filter_transaction_result(self, tx_hash: Any, result: Any) -> Any:
        if result is None:
            return None
        return result if self._transaction_allowed(str(tx_hash), result) else None

    @staticmethod
    def _params(request: dict[str, Any]) -> list[Any] | dict[str, Any]:
        params = request.get("params", [])
        if not isinstance(params, (list, dict)):
            raise PolicyError("invalid JSON-RPC params", -32602)
        return params

    @staticmethod
    def _at(params: list[Any] | dict[str, Any], index: int) -> Any:
        if not isinstance(params, list):
            raise PolicyError("positional JSON-RPC params required", -32602)
        return params[index] if len(params) > index else None

    def _forward(self, method: str, params: list[Any] | dict[str, Any]) -> Any:
        return self.backend.request(method, params)

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        request_id = request.get("id")
        method = request.get("method")
        try:
            with self._request_lock:
                self._request_count += 1
                if self._request_count > MAX_RPC_CALLS:
                    raise PolicyError("RPC request budget exhausted")
            if request.get("jsonrpc") != "2.0" or not isinstance(method, str):
                raise PolicyError("invalid JSON-RPC request", -32600)
            params = self._params(request)

            if method.startswith(("anvil_", "evm_", "hardhat_")):
                raise PolicyError("state-mutation RPC methods are unavailable")

            if method in self.TX_LOOKUP_METHODS:
                tx_hash = self._at(params, 0)
                if self.hide_prestate_history and not self._transaction_allowed(
                    str(tx_hash)
                ):
                    result = None
                else:
                    result = self._forward(method, params)
                    result = self._filter_transaction_result(tx_hash, result)
            elif method in self.RAW_TX_LOOKUP_METHODS:
                tx_hash = self._at(params, 0)
                result = (
                    self._forward(method, params)
                    if self._transaction_allowed(str(tx_hash))
                    else None
                )
            elif method in self.TX_TRACE_METHODS:
                tx_hash = self._at(params, 0)
                if not self._transaction_allowed(str(tx_hash)):
                    raise PolicyError("transaction is outside the local task history")
                result = self._forward(method, params)
            elif method in self.SEND_METHODS:
                result = self._forward(method, params)
                if isinstance(result, str) and HASH_RE.fullmatch(result):
                    with self._local_lock:
                        self.local_transactions.add(result.lower())
            elif method == "eth_getBlockByHash":
                block_hash = self._at(params, 0)
                if not self._block_hash_allowed(block_hash):
                    result = None
                else:
                    result = self._forward(
                        method,
                        self._block_params_without_prestate_bodies(params, block_hash),
                    )
            elif method == "eth_getBlockByNumber":
                block_ref = self._at(params, 0)
                if not self._block_ref_allowed(block_ref):
                    result = None
                else:
                    result = self._forward(
                        method,
                        self._block_params_without_prestate_bodies(params, block_ref),
                    )
            elif method == "eth_getBlockReceipts":
                block_ref = self._at(params, 0)
                if isinstance(block_ref, str) and HASH_RE.fullmatch(block_ref):
                    if not self._block_hash_allowed(block_ref):
                        raise PolicyError("block is outside the local task history")
                else:
                    self._require_block_ref(block_ref)
                if self._prestate_block(block_ref):
                    result = []
                else:
                    result = self._forward(method, params)
                    if self.hide_prestate_history:
                        result = self._filter_block_receipts(result)
            elif method in self.BLOCK_REF_METHODS:
                index = self.BLOCK_REF_METHODS[method]
                if isinstance(params, list) and len(params) > index:
                    self._require_visible_state_ref(params[index])
                result = self._forward(method, params)
            elif method in self.BLOCK_NUMBER_METHODS:
                block_ref = self._at(params, self.BLOCK_NUMBER_METHODS[method])
                self._require_block_ref(block_ref)
                if method in self.BLOCK_NUMBER_HISTORY_METHODS and self._prestate_block(
                    block_ref
                ):
                    if method.startswith(("eth_getRaw", "eth_getTransaction")):
                        result = None
                    else:
                        raise PolicyError("pre-state transaction history is unavailable")
                else:
                    result = self._forward(method, params)
            elif method in self.BLOCK_HASH_METHODS:
                block_hash = self._at(params, self.BLOCK_HASH_METHODS[method])
                if not self._block_hash_allowed(block_hash):
                    raise PolicyError("block is outside the local task history")
                if method in self.BLOCK_HASH_HISTORY_METHODS and self._prestate_block(
                    block_hash
                ):
                    if method.startswith(("eth_getRaw", "eth_getTransaction")):
                        result = None
                    else:
                        raise PolicyError("pre-state transaction history is unavailable")
                else:
                    result = self._forward(method, params)
            elif method in {"eth_getLogs", "eth_newFilter"}:
                query = self._at(params, 0)
                if not isinstance(query, dict):
                    raise PolicyError("invalid log filter", -32602)
                self._require_local_log_scope(query)
                if "blockHash" in query:
                    if not self._block_hash_allowed(query["blockHash"]):
                        raise PolicyError("block is outside the local task history")
                else:
                    self._require_bounded_range(
                        query.get("fromBlock", "latest"),
                        query.get("toBlock", "latest"),
                    )
                result = self._forward(method, params)
            elif method == "eth_feeHistory":
                block_count = _hex_number(self._at(params, 0))
                if block_count is None or block_count > MAX_FEE_HISTORY_BLOCKS:
                    raise PolicyError("fee history range is too large", -32602)
                self._require_block_ref(self._at(params, 1))
                result = self._forward(method, params)
            elif method == "trace_filter":
                query = self._at(params, 0)
                if not isinstance(query, dict):
                    raise PolicyError("invalid trace filter", -32602)
                self._require_bounded_range(
                    query.get("fromBlock", "latest"),
                    query.get("toBlock", "latest"),
                )
                if self.prestate_block is not None and self._block_ref_number(
                    query.get("fromBlock", "latest")
                ) <= self.prestate_block:
                    raise PolicyError("pre-state transaction history is unavailable")
                result = self._forward(method, params)
            elif method in self.SIMPLE_METHODS:
                result = self._forward(method, params)
            else:
                raise PolicyError("method unavailable on the task gateway")

            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except PolicyError as error:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": error.code, "message": error.message},
            }
        except (OSError, ValueError, json.JSONDecodeError):
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32000, "message": "task gateway unavailable"},
            }


class QuietHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def send_body(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def health(self) -> None:
        self.send_body(200, b"ok\n", "text/plain")


def rpc_handler(policy: RpcPolicy) -> type[QuietHandler]:
    class RpcHandler(QuietHandler):
        def do_GET(self) -> None:  # noqa: N802
            if urllib.parse.urlsplit(self.path).path == "/health":
                self.health()
            else:
                self.send_body(405, b"method not allowed\n", "text/plain")

        def do_POST(self) -> None:  # noqa: N802
            if urllib.parse.urlsplit(self.path).path not in {"", "/"}:
                self.send_body(404, b"not found\n", "text/plain")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if length < 0 or length > MAX_REQUEST_BYTES:
                self.send_body(413, b"request too large\n", "text/plain")
                return
            try:
                payload = json.loads(self.rfile.read(length))
                if isinstance(payload, list):
                    if (
                        not payload
                        or len(payload) > MAX_BATCH_REQUESTS
                        or not all(isinstance(item, dict) for item in payload)
                    ):
                        raise ValueError("invalid batch")
                    response: Any = [policy.handle(item) for item in payload]
                elif isinstance(payload, dict):
                    response = policy.handle(payload)
                else:
                    raise ValueError("invalid request")
                body = json.dumps(response, separators=(",", ":")).encode()
                if len(body) > MAX_RPC_RESPONSE_BYTES:
                    self.send_body(413, b"response too large\n", "text/plain")
                    return
                self.send_body(200, body, "application/json")
            except (json.JSONDecodeError, ValueError):
                body = json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": "parse error"},
                    },
                    separators=(",", ":"),
                ).encode()
                self.send_body(400, body, "application/json")

    return RpcHandler


def source_handler(
    chain_id: str,
    *,
    local_source_path: str | None = None,
    local_source_address: str | None = None,
    local_contract_name: str = "Scenario",
    local_source_registry_path: str | None = None,
) -> type[QuietHandler]:
    local_body = (
        local_source_response(local_source_path, local_contract_name)
        if local_source_path
        else None
    )
    local_address = local_source_address.lower() if local_source_address else None
    local_registry = (
        load_local_source_registry(local_source_registry_path)
        if local_source_registry_path
        else {}
    )
    local_registry_cache: dict[str, bytes] = {}

    class SourceHandler(QuietHandler):
        def do_GET(self) -> None:  # noqa: N802
            if urllib.parse.urlsplit(self.path).path == "/health":
                self.health()
                return
            try:
                address = validate_source_query(self.path, chain_id)
                cache_key = address.lower()
                if local_body is not None and cache_key == local_address:
                    self.send_body(200, local_body, "application/json")
                    return
                local_entry = local_registry.get(cache_key)
                if local_entry is not None:
                    body = local_registry_cache.get(cache_key)
                    if body is None:
                        body = local_source_response(*local_entry)
                        local_registry_cache[cache_key] = body
                    self.send_body(200, body, "application/json")
                    return
                body = json.dumps(
                    {
                        "status": "0",
                        "message": "NOTOK",
                        "result": "verified source is unavailable for this address",
                    },
                    separators=(",", ":"),
                ).encode()
                self.send_body(200, body, "application/json")
            except PolicyError as error:
                body = json.dumps(
                    {"status": "0", "message": "NOTOK", "result": error.message},
                    separators=(",", ":"),
                ).encode()
                self.send_body(403, body, "application/json")
            except (OSError, ValueError):
                body = json.dumps(
                    {
                        "status": "0",
                        "message": "NOTOK",
                        "result": "source gateway unavailable",
                    },
                    separators=(",", ":"),
                ).encode()
                self.send_body(502, body, "application/json")

        def do_POST(self) -> None:  # noqa: N802
            self.send_body(405, b"method not allowed\n", "text/plain")

        def do_CONNECT(self) -> None:  # noqa: N802
            self.send_body(405, b"method not allowed\n", "text/plain")

    return SourceHandler


def main() -> None:
    backend_url = os.environ.get("RPC_BACKEND_URL", "http://pier-anvil:8545")
    initial_block = int(os.environ.get("INITIAL_BLOCK_NUMBER", "0"))
    explorer_chain_id = os.environ.get("EXPLORER_CHAIN_ID", "1")
    if not explorer_chain_id.isdigit():
        raise ValueError("EXPLORER_CHAIN_ID must be a decimal integer")
    rpc_port = int(os.environ.get("RPC_GATEWAY_PORT", "8545"))
    source_port = int(os.environ.get("SOURCE_GATEWAY_PORT", "8081"))
    local_source_path = os.environ.get("LOCAL_SOURCE_PATH")
    local_source_address = os.environ.get("LOCAL_SOURCE_ADDRESS")
    local_contract_name = os.environ.get("LOCAL_SOURCE_CONTRACT_NAME", "Scenario")
    local_source_registry_path = os.environ.get("LOCAL_SOURCE_REGISTRY_PATH")
    if bool(local_source_path) != bool(local_source_address):
        raise ValueError("local source path and address must be configured together")
    if local_source_address and not ADDRESS_RE.fullmatch(local_source_address):
        raise ValueError("LOCAL_SOURCE_ADDRESS is invalid")
    if not local_source_path and not local_source_registry_path:
        raise ValueError("a bundled source path or registry is required")

    policy = RpcPolicy(
        Backend(backend_url),
        initial_block,
        hide_prestate_history=True,
    )
    servers = [
        ThreadingHTTPServer(("0.0.0.0", rpc_port), rpc_handler(policy)),
        ThreadingHTTPServer(
            ("0.0.0.0", source_port),
            source_handler(
                explorer_chain_id,
                local_source_path=local_source_path,
                local_source_address=local_source_address,
                local_contract_name=local_contract_name,
                local_source_registry_path=local_source_registry_path,
            ),
        ),
    ]
    threads = [threading.Thread(target=server.serve_forever) for server in servers]
    for thread in threads:
        thread.start()
    try:
        for thread in threads:
            thread.join()
    finally:
        for server in servers:
            server.shutdown()


if __name__ == "__main__":
    main()
