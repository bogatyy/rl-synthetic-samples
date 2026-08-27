// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/SableProtocol.sol";
import "../src/SablePaths.sol";
import "../src/SableQuery.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        SableCommandRouter router = new SableCommandRouter();
        LocalToken cash = new LocalToken("Sable Cash", "CASH", 18);
        LocalToken base = new LocalToken("Sable Base", "BASE", 18);
        SableSettlementVault vault = new SableSettlementVault();
        SableCurveEngine engine = new SableCurveEngine();
        SableHotPath hot = new SableHotPath(address(router), address(engine));
        SableWarmPath warm = new SableWarmPath(address(router), address(engine));
        SableColdPath cold = new SableColdPath(address(router), address(engine));
        SableCurveQuery query = new SableCurveQuery(address(engine));
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(base);
        MultiFlashBank lender = new MultiFlashBank(assets, 5);
        LocalPair conversion = new LocalPair(address(cash), address(base));
        SableClearingPolicy clearing = new SableClearingPolicy();

        vault.bind(address(engine));
        engine.configure(
            address(router),
            address(cash),
            address(base),
            address(vault),
            address(hot),
            address(warm),
            address(cold),
            address(clearing)
        );
        uint16[12] memory selected = [uint16(3), 19, 27, 44, 68, 91, 117, 142, 176, 203, 229, 251];
        uint256 targetRiskA;
        uint256 targetRiskB;
        uint256 targetRiskC;
        uint256 targetRiskD;
        for (uint256 i; i < 257; ++i) {
            uint256 entropy = uint256(keccak256(abi.encode(i)));
            uint16 grid = uint16(entropy % 4 == 0 ? 40 : entropy % 4 == 1 ? 64 : entropy % 4 == 2 ? 80 : 100);
            int24 settlement = 69_080;
            int24 tick = settlement - int24(uint24(grid * uint16(5 + (entropy >> 8) % 13)));
            uint16 feeBps = uint16(10 + (entropy >> 16) % 81);
            uint128 basePerTick = uint128((5 + (entropy >> 24) % 11) * 0.0001 ether);
            uint128 curveLiquidity = uint128(5e29 + (entropy >> 32) % 3e30);
            uint128 maximumLiquidity = uint128(5e29 + (entropy >> 128) % 8e30);
            uint128 settlementLimit = uint128((350_000 + (entropy >> 192) % 250_001) * 1 ether);
            uint16 riskA = uint16(1_000 + (entropy >> 40) % 49_001);
            uint16 riskB = uint16(1_000 + (entropy >> 88) % 49_001);
            uint16 riskC = uint16(1_000 + (entropy >> 136) % 49_001);
            uint16 riskD = uint16(1_000 + (entropy >> 176) % 49_001);
            uint80 riskCode = uint80(riskA) | uint80(riskB) << 16 | uint80(riskC) << 32 | uint80(riskD) << 48;
            uint256 poolId = 1_009 + i * 7_919 + i * i * 131;
            engine.initializePool(
                poolId, tick, settlement, grid, feeBps, basePerTick, curveLiquidity, maximumLiquidity, settlementLimit
            );
            clearing.registerPool(poolId, riskCode);
            for (uint256 j; j < selected.length; ++j) {
                if (selected[j] != i) continue;
                targetRiskA += riskA;
                targetRiskB += riskB;
                targetRiskC += riskC;
                targetRiskD += riskD;
                break;
            }
        }
        clearing.configure(12, targetRiskA, targetRiskB, targetRiskC, targetRiskD, address(engine));
        engine.finishConfiguration();
        router.configure(
            address(cash), address(base), address(vault), address(lender), address(conversion), address(query)
        );
        router.install(1, address(hot));
        router.install(2, address(warm));
        router.install(3, address(cold));
        router.finishConfiguration();

        cash.mint(address(vault), 10_000_000 ether);
        base.mint(address(vault), 5_000_000 ether);
        cash.mint(address(lender), 2_000_000 ether);
        base.mint(address(lender), 3_000 ether);
        cash.mint(address(conversion), 1_000_000 ether);
        base.mint(address(conversion), 1_000 ether);
        conversion.sync();
        cash.renounceAdministration();
        base.renounceAdministration();
        vm.stopBroadcast();
    }
}
