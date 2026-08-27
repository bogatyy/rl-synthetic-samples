#!/usr/bin/env python3
"""Confirm each synthetic reference depends on its intended bug."""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
TASKS = ROOT / "tasks"

ROOT_PATCHES: dict[str, list[tuple[str, str, str]]] = {
    "01-abecedarian": [
        (
            "AbecedarianRewardDispenser.sol",
            'require(key == 2 + 2, "key");',
            'require(key == 2 + 3, "key");',
        )
    ],
    "12-kestrel": [
        (
            "KestrelDebt.sol",
            "assets += face * 1 ether / settlementUnit * recognitionBps / 10_000;",
            """(,, uint96 faceUnit,,,) =
                KestrelInstrumentRegistry(registry).instruments(instrument);
            assets += face * 1 ether / faceUnit * recognitionBps / 10_000;""",
        )
    ],
    "13-lantern": [
        (
            "LanternMarket.sol",
            """    function register(address market) external {
        require(LanternMarketFactory(marketFactory).isMarket(market), "factory");""",
            """    function register(address market) external {
        require(msg.sender == curator, "curator");
        require(LanternMarketFactory(marketFactory).isMarket(market), "factory");""",
        ),
    ],
    "14-marrow": [
        (
            "MarrowProtocol.sol",
            ": beforeTick > tick && afterTick < tick;",
            ": beforeTick > tick && afterTick <= tick;",
        )
    ],
    "15-nimbus": [
        (
            "NimbusOracle.sol",
            "blended[cursor] = (spot + source.ema) / 2;",
            "blended[cursor] = source.ema;",
        )
    ],
    "16-opal": [
        (
            "OpalProtocol.sol",
            """    mapping(address => mapping(address => mapping(address => uint256))) public credit;""",
            """    mapping(address => mapping(address => mapping(address => uint256))) public credit;
    bool private harvestEntered;""",
        ),
        (
            "OpalProtocol.sol",
            """        OpalMarketShare(market).claimRewards(address(this));""",
            """        require(!harvestEntered, "harvest reentrancy");
        harvestEntered = true;
        OpalMarketShare(market).claimRewards(address(this));
        harvestEntered = false;""",
        )
    ],
    "17-praxis": [
        (
            "PraxisStrategy.sol",
            "uint256 observed = PraxisStrategyShare(strategy).convertToAssets(1 ether);",
            "uint256 observed = 12e17;",
        )
    ],
    "18-quartz": [
        (
            "QuartzRange.sol",
            """        uint256 growth = QuartzRangeVenue(venue).feeGrowth() - position.feeCheckpoint;
        uint256 accrued = uint256(position.liquidity) * growth >> 128;
        return uint256(position.cashAmount) + uint256(position.quoteAmount) + accrued;""",
            "        return uint256(position.cashAmount) + uint256(position.quoteAmount);",
        )
    ],
    "19-riven": [
        (
            "RivenPool.sol",
            """            uint8 output = indexOut == 0 ? 0 : 1;
            uint256 normalizedOut = rawAmountOut.mulDown(factors[indexOut]);""",
            """            uint8 output = indexOut == 0 ? 0 : 1;
            // GIVEN_OUT rounds outward while scaling the requested output.
            uint256 normalizedOut = RivenFixedPoint.mulUp(rawAmountOut, factors[indexOut]);""",
        )
    ],
    "20-sable": [
        (
            "SableMath.sol",
            """        uint256 raw = entering
            ? mulDivUp(deflatorX64, curveLiquidity, uint256(curveLiquidity) + rangeLiquidity)
            : mulDivUp(deflatorX64, uint256(curveLiquidity) + rangeLiquidity, curveLiquidity);""",
            """        uint256 raw = entering
            ? uint256(deflatorX64) * curveLiquidity / (uint256(curveLiquidity) + rangeLiquidity)
            : mulDivUp(deflatorX64, uint256(curveLiquidity) + rangeLiquidity, curveLiquidity);""",
        )
    ],
    "21-talus": [
        (
            "TalusRewards.sol",
            """    function onHashrateMovement(address from, address to, uint256) external {
        require(msg.sender == hashrate, "hashrate token");""",
            """    function onHashrateMovement(address from, address to, uint256 amount) external {
        require(msg.sender == hashrate, "hashrate token");
        if (amount == 0) return;""",
        )
    ],
    "22-umbra": [
        (
            "UmbraRouting.sol",
            "running = routeType == 2 ? reported : actual;",
            "running = actual;",
        ),
    ],
    "23-verdant": [
        (
            "VerdantCurve.sol",
            "uint256 next = sold[block.number][seller] + amount;",
            "uint256 next = sold[block.number][operator] + amount;",
        ),
        (
            "VerdantCurve.sol",
            "sold[block.number][seller] = next;",
            "sold[block.number][operator] = next;",
        ),
    ],
    "24-willow": [
        (
            "WillowTransfers.sol",
            'movementMode[bytes4(keccak256("transferFrom(address,address,uint256)"))] = 1;',
            'movementMode[bytes4(keccak256("transferFrom(address,address,uint256)"))] = 3;',
        ),
    ],
    "25-xenon": [
        (
            "XenonPolicy.sol",
            "return remainingEpochs == totalEpochs ? depositWorkLimit : 0;",
            "return remainingEpochs;",
        ),
    ],
    "26-yarrow": [
        (
            "YarrowProtocol.sol",
            "    function expressExecute(bytes calldata envelope) external {",
            """    function expressExecute(bytes calldata envelope) external {
        require(
            msg.sender == YarrowEnvelopeVerifier(messageVerifier).trustedTransport(),
            "transport"
        );""",
        ),
    ],
    "27-zephyr": [
        (
            "ZephyrEpoch.sol",
            "prepared && from == pair && amount == 0",
            "prepared && from == pair && amount != 0",
        )
    ],
    "28-alder": [
        (
            "AlderProtocol.sol",
            """            uint256 quoted = AlderThinVenue(venue).quote(input, amount);
            AlderBasketReserve(componentReserve).release(output, venue, quoted * routes[i].weight / 1 ether);""",
            """            require(routes[i].weight <= 1 ether, "weight");
            uint256 quoted = AlderThinVenue(venue).quote(input, amount);
            AlderBasketReserve(componentReserve).release(output, venue, quoted * routes[i].weight / 1 ether);""",
        )
    ],
    "29-bracken": [
        (
            "BrackenStrategies.sol",
            "return IERC20Like(bond).balanceOf(address(this)) * 1e12 * REPORT_MULTIPLIER;",
            "return accountedBond * 1e12 * REPORT_MULTIPLIER;",
        )
    ],
    "30-cinder": [
        (
            "CinderRisk.sol",
            """        uint256 currentValue = CinderPriceBook(priceBook).valueInCash(wrapper, shares);
        return currentValue * market.collateralFactorBps / 10_000;""",
            """        return shares * uint256(market.debtPrice) / 1 ether * market.collateralFactorBps / 10_000;""",
        )
    ],
    "31-dovetail": [
        (
            "DovetailModules.sol",
            """        address callback = hook[product];
        if (callback != address(0)) IDovetailIssueHook(callback).beforeIssue(product, quantity, recipient);
        token.mint(recipient, quantity);""",
            """        token.mint(recipient, quantity);
        address callback = hook[product];
        if (callback != address(0)) IDovetailIssueHook(callback).beforeIssue(product, quantity, recipient);""",
        )
    ],
}


def run() -> None:
    failures: list[str] = []
    task_filter = os.environ.get("SYNTHETIC_COUNTERFACTUAL_TASK")
    port_base = int(os.environ.get("SYNTHETIC_COUNTERFACTUAL_PORT_BASE", "42000"))
    executed = 0
    with tempfile.TemporaryDirectory(prefix="rl-synthetic-counterfactual.") as temp:
        temp_root = pathlib.Path(temp)
        index = 0
        for task_id, root_patches in ROOT_PATCHES.items():
            if not (TASKS / task_id).is_dir():
                continue
            if task_filter and task_id != task_filter:
                continue
            variants = {"root-cause": root_patches}
            for variant, patches in variants.items():
                executed += 1
                scenario_id = f"{task_id}-{variant}"
                source = TASKS / task_id / "environment/scenario"
                scenario = temp_root / scenario_id
                shutil.copytree(
                    source,
                    scenario,
                    ignore=shutil.ignore_patterns("out", "cache", "broadcast"),
                )
                for filename, old, new in patches:
                    path = scenario / "src" / filename
                    text = path.read_text()
                    if text.count(old) != 1:
                        raise RuntimeError(
                            f"counterfactual anchor changed: {task_id}/{variant}/{filename}"
                        )
                    path.write_text(text.replace(old, new))

                subprocess.run(
                    ["forge", "build", "--root", str(scenario), "--offline"],
                    cwd=ROOT,
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                environment = os.environ.copy()
                environment.update(
                    {
                        "SMOKE_SCENARIO_PATH": str(scenario),
                        "SMOKE_PORT_BASE": str(port_base + index * 100),
                        "SMOKE_TRACE_ON_FAILURE": "0",
                    }
                )
                index += 1
                result = subprocess.run(
                    [str(ROOT / "scripts/smoke_test.sh"), task_id],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
                rejected_by_grader = result.returncode != 0 and (
                    "[smoke] grade transaction failed" in result.stdout
                    or "[smoke] grader did not pass" in result.stdout
                )
                if rejected_by_grader:
                    print(
                        f"[counterfactual] {task_id}/{variant}: reference rejected",
                        flush=True,
                    )
                else:
                    failures.append(scenario_id)
                    print(result.stdout)
                    print(
                        f"[counterfactual] {task_id}/{variant}: unexpected result",
                        flush=True,
                    )

    if failures:
        raise SystemExit("counterfactual failures: " + ", ".join(failures))
    print(f"[counterfactual] all {executed} selected controls were rejected")


if __name__ == "__main__":
    run()
