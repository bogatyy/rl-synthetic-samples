#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_root="$repo_root/tasks"

expected_tasks=(
  01-abecedarian
  12-kestrel 14-marrow 15-nimbus 16-opal
  17-praxis 18-quartz 21-talus
  23-verdant 24-willow 25-xenon
  29-bracken 30-cinder
  34-garnet 35-harbor 41-nacre
  45-rowan 46-saffron 52-yonder
  119-org-riven 120-org-sable
)

tasks=()
while IFS= read -r task_id; do
  tasks+=("$task_id")
done < <(
  find "$task_root" -mindepth 2 -maxdepth 2 -name task.toml -print \
    | sed 's#/task.toml$##' | xargs -n1 basename | LC_ALL=C sort -t- -k1,1n
)
[[ "${tasks[*]}" == "${expected_tasks[*]}" ]]

listed=()
while IFS= read -r task_id; do
  listed+=("$task_id")
done < <(awk -F'"' '/^name = "rl-exploits\// {print $2}' "$task_root/dataset.toml" | sed 's#rl-exploits/##')
[[ "${tasks[*]}" == "${listed[*]}" ]]

core_image_ready=0
task_docker_image() {
  local task_id=$1
  awk -F'"' '
    /^\[environment\]$/ { in_section=1; next }
    in_section && /^\[/ { exit }
    in_section && $1 ~ /^docker_image[[:space:]]*=[[:space:]]*$/ { print $2; exit }
  ' "$task_root/$task_id/task.toml"
}

ensure_task_image() {
  local task_id=$1 task_image
  task_image=$(task_docker_image "$task_id")
  [[ -n "$task_image" ]]
  if (( core_image_ready == 0 )); then
    if ! docker image inspect rl-exploits-foundry-core:latest >/dev/null 2>&1; then
      docker build --tag rl-exploits-foundry-core:latest "$repo_root/docker/core" >&2
    fi
    core_image_ready=1
  fi
  if ! docker image inspect "$task_image" >/dev/null 2>&1; then
    docker build --tag "$task_image" "$task_root/$task_id/environment" >&2
  fi
  printf '%s\n' "$task_image"
}

validation_root=$(mktemp -d /tmp/rl-synthetic-validate.XXXXXX)
cleanup() {
  case "$validation_root" in /tmp/rl-synthetic-validate.*) rm -rf -- "$validation_root" ;; esac
}
trap cleanup EXIT

for task_id in "${tasks[@]}"; do
  task_dir="$task_root/$task_id"
  scenario="$task_dir/environment/scenario"
  target=$(awk -F'"' '/^target_contract_address = / { print $2; exit }' "$task_dir/task.toml")
  chain_id=$(awk -F' = ' '/^chain_id = / { print $2; exit }' "$task_dir/task.toml")
  echo "[synthetic-validate] $task_id"
  [[ "$task_id" =~ ^[0-9]{2,3}-[a-z][a-z0-9-]*$ ]]
  [[ "$chain_id" =~ ^[0-9]+$ ]]

  for required in task.toml instruction.md pre_artifacts.sh \
    environment/.dockerignore environment/Dockerfile \
    environment/project/src/Exploit.sol environment/scenario/foundry.toml \
    environment/scenario/script/Setup.s.sol \
    environment/scenario/source-registry.json tests/Dockerfile tests/test.sh \
    tests/ExploitGrader.sol solution/Exploit.sol solution/solve.sh; do
    [[ -f "$task_dir/$required" ]] || { echo "missing $task_id/$required" >&2; exit 1; }
  done
  [[ -x "$task_dir/pre_artifacts.sh" ]]
  [[ -x "$task_dir/tests/test.sh" ]]
  [[ -x "$task_dir/solution/solve.sh" ]]
  [[ ! -e "$scenario/src/Scenario.sol" ]]
  (( $(find "$scenario/src" -maxdepth 1 -type f \( -name '*.sol' -o -name '*.vy' \) | wc -l) >= 1 ))

  grep -q "target_contract_address = \"$target\"" "$task_dir/task.toml"
  grep -q '^chain = "local"$' "$task_dir/task.toml"
  grep -q '^CHAIN_MODE = "local"$' "$task_dir/task.toml"
  grep -q '^SCENARIO_SETUP_SCRIPT = "script/Setup.s.sol:Setup"$' "$task_dir/task.toml"
  grep -q '^SCENARIO_SOURCE_REGISTRY = "/opt/scenario/source-registry.json"$' "$task_dir/task.toml"
  ! grep -q 'SCENARIO_SOURCE_PATH\|SCENARIO_CONTRACT =\|ARCHIVE_RPC_URL\|FORK_' \
    "$task_dir/task.toml" "$task_dir/environment/Dockerfile"

  python3 - "$scenario/source-registry.json" "$scenario/src" "$target" <<'PY'
import json
import pathlib
import re
import sys

registry_path = pathlib.Path(sys.argv[1])
source_root = pathlib.Path(sys.argv[2])
scenario_root = source_root.parent
target = sys.argv[3].lower()
registry = json.loads(registry_path.read_text())
assert len(registry) >= 1
assert len({address.lower() for address in registry}) == len(registry)
for address, entry in registry.items():
    assert re.fullmatch(r"0x[0-9A-Fa-f]{40}", address)
    metadata_fields = {
        "language", "compiler_version", "optimization_used", "optimizer_runs",
        "evm_version", "license_type",
    }
    assert {"path", "name"} <= set(entry) <= {
        "path", "name", "sources", "sources_root", *metadata_fields,
    }
    assert not ("sources" in entry and "sources_root" in entry)
    assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", entry["name"])
    language = entry.get("language", "Solidity")
    assert language in {"Solidity", "Vyper"}
    suffix = ".sol" if language == "Solidity" else ".vy"
    for field in ("compiler_version", "evm_version", "license_type"):
        if field in entry:
            value = entry[field]
            assert isinstance(value, str) and 0 < len(value) <= 128
            assert all(32 <= ord(character) < 127 for character in value)
    if "optimization_used" in entry:
        value = entry["optimization_used"]
        assert isinstance(value, (bool, int, str)) and value in {False, True, 0, 1, "0", "1"}
    if "optimizer_runs" in entry:
        value = entry["optimizer_runs"]
        assert not isinstance(value, bool) and isinstance(value, (int, str))
        assert int(value) >= 0
    prefix = "/opt/scenario/src/"
    assert entry["path"].startswith(prefix)
    relative = entry["path"][len(prefix):]
    assert relative.endswith(suffix)
    assert not relative.startswith("/") and ".." not in pathlib.PurePosixPath(relative).parts
    source = source_root / relative
    assert source.is_file()
    if language == "Solidity":
        assert re.search(rf"\b(?:contract|library)\s+{re.escape(entry['name'])}\b", source.read_text())
    if "sources_root" in entry:
        bundled_root = entry["sources_root"]
        assert isinstance(bundled_root, str)
        assert bundled_root == "/opt/scenario" or bundled_root.startswith("/opt/scenario/")
        assert ".." not in pathlib.PurePosixPath(bundled_root).parts
        relative_root = bundled_root.removeprefix("/opt/scenario").lstrip("/")
        local_root = scenario_root / relative_root
        assert local_root.resolve().is_relative_to(scenario_root.resolve())
        assert local_root.is_dir()
        excluded = {".git", "broadcast", "cache", "out", "script", "scripts", "solution", "solutions", "test", "tests"}
        bundled_files = [
            item for item in local_root.rglob(f"*{suffix}")
            if item.is_file() and not item.is_symlink()
            and not any(part in excluded for part in item.relative_to(local_root).parts)
        ]
        assert bundled_files
        assert source.resolve() in {item.resolve() for item in bundled_files}
    else:
        sources = entry.get("sources", {pathlib.PurePosixPath(entry["path"]).name: entry["path"]})
        assert isinstance(sources, dict) and sources
        assert entry["path"] in sources.values()
        for logical_name, bundled_path in sources.items():
            logical_path = pathlib.PurePosixPath(logical_name)
            assert logical_name.endswith(suffix)
            assert not logical_path.is_absolute() and ".." not in logical_path.parts
            assert bundled_path.startswith(prefix)
            bundled_relative = bundled_path[len(prefix):]
            assert ".." not in pathlib.PurePosixPath(bundled_relative).parts
            assert (source_root / bundled_relative).resolve().is_relative_to(source_root.resolve())
            assert (source_root / bundled_relative).is_file()

target_entry = next(
    (entry for address, entry in registry.items() if address.lower() == target),
    None,
)
task_id = source_root.parent.parent.parent.name
if task_id == "01-abecedarian":
    assert target_entry is not None
    assert target_entry == {
        "path": "/opt/scenario/src/AbecedarianRewardDispenser.sol",
        "name": "AbecedarianRewardDispenser",
        "sources": {
            "AbecedarianRewardDispenser.sol": "/opt/scenario/src/AbecedarianRewardDispenser.sol"
        },
    }
elif int(task_id.split("-", 1)[0]) <= 11:
    assert target_entry is not None
    assert target_entry["path"] == "/opt/scenario/src/RelayProxy.sol"
    assert target_entry["name"] == "RelayProxy"
    assert "RelayProxy.sol" in target_entry["sources"]
elif target_entry is not None:
    assert target_entry["path"].startswith("/opt/scenario/src/")
    assert target_entry["name"] != "RelayProxy"
assert all("Setup" not in entry["path"] for entry in registry.values())
PY

  if [[ "$task_id" == 01-abecedarian ]]; then
    grep -q 'This task is not an exploit' "$task_dir/instruction.md"
    grep -q 'result of the calculation `2 + 2`' "$task_dir/instruction.md"
    grep -q 'as few agent turns as possible' "$task_dir/instruction.md"
    grep -q 'entire 1 ETH reward' "$task_dir/instruction.md"
  else
    grep -q "Audit \`$target\`" "$task_dir/instruction.md"
    grep -q 'pass,' "$task_dir/instruction.md"
    grep -q '1-hour research budget' "$task_dir/instruction.md"
  fi
  grep -q 'external `execute()` function' "$task_dir/instruction.md"
  grep -q 'ordinary deployments and transactions' "$task_dir/instruction.md"
  grep -q 'state-mutation RPCs' "$task_dir/instruction.md"
  grep -Eq 'function[[:space:]]+execute\(\)[[:space:]]*external' "$task_dir/solution/Exploit.sol"
  grep -Eq 'bool[[:space:]]+public[[:space:]]+passed[[:space:]]*;' "$task_dir/tests/ExploitGrader.sol"
  grep -Eq 'function[[:space:]]+grade\(\)[[:space:]]*external' "$task_dir/tests/ExploitGrader.sol"
  grep -Eq "block\\.chainid[[:space:]]*==[[:space:]]*$chain_id([^0-9]|$)" \
    "$task_dir/tests/ExploitGrader.sol"
  grep -qi 'minimum' "$task_dir/tests/ExploitGrader.sol"
  grep -qi 'outflow' "$task_dir/tests/ExploitGrader.sol"
  grep -qi 'proceeds' "$task_dir/tests/ExploitGrader.sol"

  visible_sources=()
  while IFS= read -r source_name; do
    visible_sources+=("$source_name")
  done < <(
    find "$scenario/src" -type f \( -name '*.sol' -o -name '*.vy' \) | LC_ALL=C sort
  )
  ! rg -n '\bvm\.|\bhevm\b|anvil_(set|impersonate)|eth_sendRawTransaction' \
    "$task_dir/solution/Exploit.sol" "${visible_sources[@]}"
  ! rg -n '\b(store|deal|etch|warp|roll|prank|startPrank|setNonce|setCode)\s*\(' \
    "$scenario/script/Setup.s.sol"

  scenario_project="$validation_root/$task_id-scenario"
  cp -R "$scenario" "$scenario_project"
  scenario_solc=$(
    awk '$1 == "ENV" && index($2, "SCENARIO_SOLC=") == 1 {
      sub("^SCENARIO_SOLC=", "", $2); print $2
    }' "$task_dir/environment/Dockerfile" | tail -1
  )
  if [[ "$scenario_solc" =~ ^/usr/local/bin/solc-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    task_image=$(ensure_task_image "$task_id")
    docker run --rm --user "$(id -u):$(id -g)" --env HOME=/tmp \
      --volume "$scenario_project:/scenario" --workdir /scenario \
      --entrypoint /usr/bin/env "$task_image" -u FOUNDRY_SOLC \
      forge build --root /scenario --offline --jobs 1 --force \
      --use "$scenario_solc" >/dev/null 2>&1
  else
    forge build --root "$scenario_project" --offline --jobs 1 --force --use 0.8.28 >/dev/null 2>&1
  fi
  project="$validation_root/$task_id"
  mkdir -p "$project"
  cp -R "$repo_root/docker/core/project/." "$project/"
  cp "$task_dir/solution/Exploit.sol" "$project/src/Exploit.sol"
  cp "$task_dir/tests/ExploitGrader.sol" "$project/src/ExploitGrader.sol"
  forge build --root "$project" --offline --jobs 1 --use 0.8.28 >/dev/null 2>&1
done

historical_branding_paths=()
for task_id in "${tasks[@]}"; do
  [[ "$task_id" =~ ^(3[2-9]|4[0-9]|5[0-2])- ]] && continue
  [[ "$task_id" =~ ^(119-org-riven|120-org-sable)$ ]] && continue
  historical_branding_paths+=(
    "$task_root/$task_id/instruction.md"
    "$task_root/$task_id/task.toml"
    "$task_root/$task_id/environment/project"
    "$task_root/$task_id/environment/scenario/src"
    "$task_root/$task_id/environment/scenario/script"
  )
done
if rg -i -l '\bbalancer\b|perpetual protocol|ocean protocol|juicebox|truebit|equilibria|size credit|royal royalties|univ3 collateral|yearn|exactly finance|kyber|uwu|penpie|lava lending|impermax|ambient finance|usual money|d3xai|fractal protocol|new market trading|cook finance|edel xstock|exchange issuance|lixir|dlmc|thetanuts|whalebit|stake on me|futureswap|bebop' \
  "${historical_branding_paths[@]}" >/dev/null; then
  echo "historical protocol branding leaked into an agent-visible synthetic task" >&2
  exit 1
fi

echo "[synthetic-validate] all ${#tasks[@]} local Harbor tasks passed static validation"
