// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/PraxisRange.sol";
import "../src/PraxisStrategy.sol";
import "../src/PraxisProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        vm.startBroadcast(KEY);
        PraxisLeveragedLiquidity lending = new PraxisLeveragedLiquidity();
        LocalToken cash = new LocalToken("Praxis Settlement Cash", "CASH", 18);
        LocalToken base = new LocalToken("Praxis Range Base", "PBASE", 18);
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(base);
        MultiFlashBank[] memory banks = new MultiFlashBank[](4);
        address[] memory bankAddresses = new address[](4);
        for (uint256 i; i < banks.length; ++i) {
            banks[i] = new MultiFlashBank(assets, uint16(7 + i * 2));
            bankAddresses[i] = address(banks[i]);
        }

        PraxisRangePool[] memory pools = new PraxisRangePool[](21);
        PraxisStrategyShare[] memory strategies = new PraxisStrategyShare[](21);
        PraxisYieldEscrow[] memory escrows = new PraxisYieldEscrow[](21);
        PraxisRateOracle[] memory oracles = new PraxisRateOracle[](21);
        PraxisCompoundingCoordinator[] memory coordinators = new PraxisCompoundingCoordinator[](21);
        address[] memory oracleAddresses = new address[](21);
        uint16[] memory weights = new uint16[](21);

        // Keep every deployment contiguous. The source registry derives
        // contract addresses from this deployment sequence, while ordinary
        // configuration calls also consume the broadcaster's nonce.
        for (uint256 i; i < 21; ++i) {
            uint128 minimumCash = uint128((20 + (i * 7_919 + i * i * 3_571 + 7) % 25) * 1_000 ether);
            uint128 minimumBase = uint128((20 + (i * 4_567 + i * i * 7_919 + 13) % 25) * 1_000 ether);
            uint256 trancheSize = 150 + (i * 1_237 + i * i * 2_017 + 23) % 450;
            pools[i] = new PraxisRangePool(address(cash), address(base));
            strategies[i] = new PraxisStrategyShare(address(cash), address(base), address(pools[i]));
            escrows[i] = new PraxisYieldEscrow(address(cash), trancheSize * 1_000 ether);
            oracles[i] = new PraxisRateOracle(address(strategies[i]));
            coordinators[i] = new PraxisCompoundingCoordinator(
                address(pools[i]),
                address(strategies[i]),
                address(escrows[i]),
                address(oracles[i]),
                minimumCash,
                minimumBase
            );

            oracleAddresses[i] = address(oracles[i]);
            weights[i] = uint16(3 + (i * 17 + i * i * 5 + 11) % 25);
        }
        PraxisPortfolioOracle portfolio = new PraxisPortfolioOracle(oracleAddresses, weights);

        cash.mint(DEPLOYER, 7_000_000 ether);
        base.mint(DEPLOYER, 7_000_000 ether);
        for (uint256 i; i < 21; ++i) {
            cash.approve(address(pools[i]), type(uint256).max);
            base.approve(address(pools[i]), type(uint256).max);
            pools[i].seed(300_000 ether, 300_000 ether);
            uint128 initial =
                uint128((i == 0 ? uint256(2_000) : 150 + (i * 3_571 + i * i * 733 + 19) % 500) * 1_000 ether);
            cash.mint(address(strategies[i]), initial);
            base.mint(address(strategies[i]), initial);
            strategies[i].initialize(initial, initial, DEPLOYER);
            cash.mint(address(escrows[i]), (150 + (i * 1_237 + i * i * 2_017 + 23) % 450) * 7_000 ether);

            strategies[i].bindCoordinator(address(coordinators[i]));
            pools[i].bindCoordinator(address(coordinators[i]));
            escrows[i].bind(address(strategies[i]));
            oracles[i].bind(address(coordinators[i]));
            oracles[i].registerConsumer(address(lending));
            coordinators[i].bindLender(address(lending));
        }

        cash.mint(address(lending), 5_000_000 ether);
        for (uint256 i; i < banks.length; ++i) {
            cash.mint(address(banks[i]), 650_000 ether);
            base.mint(address(banks[i]), 85_000 ether);
        }
        lending.configure(
            address(cash),
            address(base),
            bankAddresses,
            address(strategies[0]),
            address(pools[0]),
            address(coordinators[0]),
            address(portfolio)
        );
        portfolio.registerConsumer(address(lending));
        cash.renounceAdministration();
        base.renounceAdministration();
        vm.stopBroadcast();
    }
}
