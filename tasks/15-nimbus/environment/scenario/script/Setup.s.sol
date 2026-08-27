// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/NimbusOracle.sol";
import "../src/NimbusProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function _weight(uint256 index) private pure returns (uint16) {
        return uint16(5 + (index * 53 + index * index * 17 + 97) % 191);
    }

    function _depth(uint256 index) private pure returns (uint256) {
        return (20_000 + (index * 7_919 + index * index * 104_729 + 12_345) % 170_000) * 1 ether;
    }

    function run() external {
        vm.startBroadcast(KEY);
        NimbusMarginPool margin = new NimbusMarginPool();
        LocalToken cash = new LocalToken("Nimbus Settlement Cash", "CASH", 18);
        LocalToken collateral = new LocalToken("Nimbus Collateral", "NIM", 18);
        address[] memory loanAssets = new address[](2);
        loanAssets[0] = address(cash);
        loanAssets[1] = address(collateral);
        MultiFlashBank[] memory banks = new MultiFlashBank[](7);
        address[] memory bankAddresses = new address[](7);
        for (uint256 i; i < banks.length; ++i) {
            banks[i] = new MultiFlashBank(loanAssets, uint16(5 + i));
            bankAddresses[i] = address(banks[i]);
        }

        address[] memory pairs = new address[](127);
        uint16[] memory weights = new uint16[](127);
        uint16[] memory observationBps = new uint16[](127);
        for (uint256 i; i < pairs.length; ++i) {
            uint256 kind = (i / 4) % 3;
            if (kind == 0) pairs[i] = address(new LocalPair(address(cash), address(collateral)));
            else if (kind == 1) pairs[i] = address(new NimbusStableVenue(address(cash), address(collateral)));
            else pairs[i] = address(new NimbusWeightedVenue(address(cash), address(collateral)));
            weights[i] = _weight(i);
            observationBps[i] = uint16(2_000 + (i % 5) * 500);
        }
        NimbusCompositeOracle oracle = new NimbusCompositeOracle(pairs, weights, observationBps);
        NimbusPositionBook book = new NimbusPositionBook();

        cash.mint(address(margin), 5_000_000 ether);
        for (uint256 i; i < banks.length; ++i) {
            cash.mint(address(banks[i]), 410_000 ether);
            collateral.mint(address(banks[i]), 410_000 ether);
        }
        for (uint256 i; i < pairs.length; ++i) {
            uint256 depth = _depth(i);
            cash.mint(pairs[i], depth);
            collateral.mint(pairs[i], depth);
            (bool synced,) = pairs[i].call(abi.encodeWithSignature("sync()"));
            require(synced, "venue sync");
        }

        uint256 seededCollateral;
        for (uint160 i; i < 127; ++i) {
            uint256 collateralUnits = 80_000 + (i * 7_919 + i * i * 104_729 + 12_345) % 260_001;
            uint256 debtRatioBps = 5_500 + (i * 53 + i * i * 17 + 97) % 3_001;
            uint128 amount = uint128(collateralUnits * 1 ether);
            uint128 debt = uint128(collateralUnits * debtRatioBps / 10_000 * 1 ether);
            address account = address(0xA100 + i * 29);
            book.seed(account, amount, debt);
            seededCollateral += amount;
        }
        collateral.mint(address(margin), seededCollateral);

        margin.configure(address(cash), address(collateral), address(oracle), address(book));
        oracle.registerConsumer(address(margin));
        book.bind(address(margin));
        book.freeze();
        margin.freeze();
        cash.renounceAdministration();
        collateral.renounceAdministration();
        vm.stopBroadcast();
    }
}
