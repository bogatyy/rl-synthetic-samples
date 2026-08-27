# Synthetic EVM audit tasks

This repository contains 21 Harbor tasks for testing smart-contract auditing
and exploit construction without relying on known contract names or historical
chain state. `01-abecedarian` is a one-call reward smoke test; the other 20 are
independent, multi-contract protocols with deliberately subtle bugs.

Every task starts from a blank local Anvil chain. Setup uses ordinary
deployments and transactions, and all contract sources are bundled in the task
image and exposed through the local `cast source` endpoint. No archive RPC,
Etherscan key, or internet access is required.

## Tasks

- `01-abecedarian`
- `12-kestrel`
- `13-lantern`
- `14-marrow`
- `15-nimbus`
- `16-opal`
- `17-praxis`
- `18-quartz`
- `19-riven`
- `20-sable`
- `21-talus`
- `22-umbra`
- `23-verdant`
- `24-willow`
- `25-xenon`
- `26-yarrow`
- `27-zephyr`
- `28-alder`
- `29-bracken`
- `30-cinder`
- `31-dovetail`

Each task has the same agent-facing interface: edit `/app/src/Exploit.sol`,
define `contract Exploit`, and expose `execute()`.

## Running

Build and run a bundled reference solution:

```bash
./runner/run.sh --smoke 01-abecedarian
```

Run a Harbor agent after installing `pier` and setting the selected model
provider key in `.env`:

```bash
./runner/run.sh --task 12-kestrel \
  --agent mini-swe-agent \
  --model openai/gpt-5.6-sol
```

Run the full validation suite:

```bash
./scripts/validate_synthetic.sh
./scripts/validate_independent_runtime.sh
./scripts/validate_independent_counterfactuals.sh
```

The `ETHERSCAN_API_KEY=source-only` value inside task definitions is a fixed,
non-secret compatibility value used by Foundry's `cast source` command. The
endpoint is a local server backed only by the bundled source files.
