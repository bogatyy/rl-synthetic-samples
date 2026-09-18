#!/usr/bin/env python3
"""Confirm each compact synthetic reference depends on its intended bug."""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
TASKS = ROOT / "tasks"
SUPPORTED_TASKS = {
    "01-abecedarian",
    "12-kestrel",
    "14-marrow",
    "15-nimbus",
    "16-opal",
    "17-praxis",
    "18-quartz",
    "21-talus",
    "23-verdant",
    "24-willow",
    "25-xenon",
    "29-bracken",
    "30-cinder",
}

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
    # These mappings describe the archived first rewrites under
    # backups/32-52-first-rewrites. The active organic reconstructions use
    # reference/no-op runtime controls instead.
    "32-eclipse": [
        (
            "EclipseAuthorization.sol",
            '        require(!prohibitedSigner[recovered], "signer policy");',
            '        require(recovered == account && !prohibitedSigner[recovered], "signer policy");',
        )
    ],
    "33-falcon": [
        (
            "FalconPricing.sol",
            """        uint256 immediatelyAvailable = IFalconBalanceReader(settlementAsset).balanceOf(reserveAccount);
        return (virtualSettlement + immediatelyAvailable) * 1 ether / virtualInventory;""",
            "        return referencePrice;",
        )
    ],
    "34-garnet": [
        (
            "GarnetToken.sol",
            """            super._move(owner, receiver, amount);
            super._move(owner, receiver, amount);
            return;""",
            """            super._move(owner, receiver, amount);
            return;""",
        )
    ],
    "35-harbor": [
        (
            "HarborProtocol.sol",
            "uint256 required = asset.balanceOf(address(this)) * shares / supply;",
            "uint256 required = (asset.balanceOf(address(this)) * shares + supply - 1) / supply;",
        )
    ],
    "36-ivory": [
        (
            "IvoryProtocol.sol",
            """    function userBurn(uint256 amount) external {
        uint256 capacity = burnCapacity[msg.sender];""",
            """    function userBurn(uint256 amount) external {
        require(msg.sender == treasury, "treasury");
        uint256 capacity = burnCapacity[msg.sender];""",
        )
    ],
    "37-juniper": [
        (
            "JuniperProtocol.sol",
            """    function triggerAutoBurn() external {
        require(block.timestamp >= lastBurnTimestamp + BURN_INTERVAL, "interval");""",
            """    function triggerAutoBurn() external {
        require(msg.sender == administrator, "administrator");
        require(block.timestamp >= lastBurnTimestamp + BURN_INTERVAL, "interval");""",
        )
    ],
    "38-kingfisher": [
        (
            "Protocol.sol",
            """    function sync() external {
        uint256 amount = reserveToken.balanceOf(address(this));""",
            """    function sync() external {
        require(msg.sender == administrator, "administrator");
        uint256 amount = reserveToken.balanceOf(address(this));""",
        )
    ],
    "39-lodestar": [
        (
            "Protocol.sol",
            """        Position memory position = positions[msg.sender]; require(position.active, "position");
        delete positions[msg.sender];""",
            """        Position memory position = positions[msg.sender]; require(position.active, "position");
        require(block.timestamp >= uint256(position.openedAt) + 1 days, "position locked");
        delete positions[msg.sender];""",
        )
    ],
    "40-mistral": [
        (
            "Protocol.sol",
            """            if (burnsPair) {
                uint256 fundAmount = amount / 2;""",
            """            if (false && burnsPair) {
                uint256 fundAmount = amount / 2;""",
        )
    ],
    "41-nacre": [
        (
            "NacreVault.sol",
            "accountedAssets = (supplyBefore + shares) * settledSharePrice / SHARE_PRICE_SCALE;",
            "accountedAssets += assets;",
        )
    ],
    "42-onyx": [
        (
            "OnyxMarket.sol",
            "        uint256 current = markPrice();",
            "        uint256 current = position.entryPrice;",
        )
    ],
    "43-palisade": [
        (
            "PalisadeMarket.sol",
            "        if (executionMode == 2) return PalisadeSpotPool(referencePool).spotPrice();",
            "        if (executionMode == 2) return this.consult();",
        )
    ],
    "44-quill": [
        (
            "QuillProtocol.sol",
            "        markedAssets = address(this).balance;",
            "        markedAssets = poolBalance;",
        )
    ],
    "45-rowan": [
        (
            "RowanProtocol.sol",
            """        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        if (to == marketPair && from != reserveVault) {""",
            """        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (to == marketPair && from != reserveVault) {""",
        ),
        (
            "RowanProtocol.sol",
            """            }
        }
        balanceOf[to] += amount;
    }
}

interface IRowanAsset {""",
            """            }
        }
    }
}

interface IRowanAsset {""",
        ),
    ],
    "46-saffron": [
        (
            "SaffronProtocol.sol",
            """        uint256 recipientAmount = amount - transactionFee;
        uint256 count = feeRegistry.distributionCount(group);""",
            """        uint256 recipientAmount = amount - transactionFee;
        uint256 totalShare = feeRegistry.shareTotal(group);
        require(totalShare != 0, "fee shares");
        uint256 count = feeRegistry.distributionCount(group);""",
        ),
        (
            "SaffronProtocol.sol",
            "            uint256 distributed = transactionFee * share / 100;",
            "            uint256 distributed = transactionFee * share / totalShare;",
        ),
    ],
    "47-thicket": [
        (
            "ThicketPerpetualMarket.sol",
            "uint256 feeUnits = stableNotional * FEE_RATE_WAD / 1e18;",
            "uint256 feeUnits = FEE_RATE_WAD * 10_000 / 1e18;",
        )
    ],
    "48-updraft": [
        (
            "UpdraftRewardTreasury.sol",
            "        uint256 deserved = router.quote(address(rewardToken), address(wrappedNative), amount);",
            "        uint256 deserved = amount * 5e13 / 1e18;",
        )
    ],
    "49-vellum": [
        (
            "VellumSettlement.sol",
            """            Interaction calldata interaction = interactions[i];
            require(interaction.target != address(balanceManager), "balance manager target");""",
            """            Interaction calldata interaction = interactions[i];
            require(!supportedAsset[interaction.target], "asset interaction");
            require(interaction.target != address(balanceManager), "balance manager target");""",
        ),
        (
            "VellumSettlement.sol",
            """            Interaction memory interaction = interactions[i];
            require(interaction.target != address(balanceManager), "balance manager target");""",
            """            Interaction memory interaction = interactions[i];
            require(!supportedAsset[interaction.target], "asset interaction");
            require(interaction.target != address(balanceManager), "balance manager target");""",
        ),
    ],
    "50-wren": [
        (
            "Protocol.sol",
            """    function burn(address account, uint256 amount, uint256 index) external onlyPool returns (uint256 scaled) {
        scaled = _rayDivNearest(amount, index);""",
            """    function burn(address account, uint256 amount, uint256 index) external onlyPool returns (uint256 scaled) {
        scaled = (amount * RAY + index - 1) / index;""",
        )
    ],
    "51-xylem": [
        (
            "Protocol.sol",
            """        if (whiteAddress[from] == 1 || whiteAddress[to] == 1) {
            _rawMove(from, to, amount);
        }""",
            """        if (whiteAddress[from] == 1 || whiteAddress[to] == 1) {
            _rawMove(from, to, amount);
            return;
        }""",
        )
    ],
    "52-yonder": [
        (
            "Protocol.sol",
            """        if (to == address(this)) {
            _burn(from, amount);
            require(backingAsset.transfer(from, amount), "redemption transfer");
            emit Redeemed(from, amount, amount);""",
            """        if (to == address(this)) {
            Program memory program = programs[address(this)];
            uint256 assets = amount * 10_000 / program.entryMultiplierBps;
            _burn(from, amount);
            require(backingAsset.transfer(from, assets), "redemption transfer");
            emit Redeemed(from, amount, assets);""",
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
            if task_id not in SUPPORTED_TASKS:
                continue
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
                foundry_config = scenario / "foundry.toml"
                configured_solc = pathlib.Path("/usr/local/bin/solc-0.8.28")
                if foundry_config.is_file() and not configured_solc.is_file():
                    config_text = foundry_config.read_text()
                    config_text = config_text.replace(
                        'solc = "/usr/local/bin/solc-0.8.28"',
                        'solc_version = "0.8.28"',
                    )
                    foundry_config.write_text(config_text)
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
