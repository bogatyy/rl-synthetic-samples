// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/XenonLiquidity.sol";
import "../src/XenonProtocol.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        EpochVault vault = new EpochVault();
        LocalToken cash = new LocalToken("Xenon Settlement", "CASH", 18);
        SnapshotBook book = new SnapshotBook(312);
        RedemptionPolicy policy = new RedemptionPolicy(uint128(10_000));
        CheckpointPolicy checkpoint = new CheckpointPolicy(57, 312);
        address[] memory lenders = new address[](9);
        for (uint256 i; i < lenders.length; ++i) {
            uint16 fee = uint16(3 + i);
            if (i == 0 || i == 6) lenders[i] = address(new XenonSimpleBank(address(cash), fee));
            else if (i == 1 || i == 8) lenders[i] = address(new XenonBatchBank(address(cash), fee));
            else if (i == 2 || i == 7) lenders[i] = address(new XenonRangeBank(address(cash), i == 2, fee));
            else if (i == 3) lenders[i] = address(new FeeFlashBank(address(cash), fee));
            else if (i == 4) lenders[i] = address(new XenonCallbackBank(address(cash), fee));
            else lenders[i] = address(new XenonPullBank(address(cash), fee));
        }

        book.bind(address(vault));
        vault.configure(address(cash), address(book), address(policy), address(checkpoint));
        checkpoint.registerVault(address(vault));
        vault.bootstrap(address(0xB0b), 100_000_000 ether, 100_000_000 ether);

        uint256 scheduled;
        for (uint32 i; i < 312; ++i) {
            int256 result = book.realizedAssets(i);
            if (result > 0) scheduled += uint256(result);
        }
        cash.mint(address(vault), 100_000_000 ether + scheduled);
        uint256[9] memory liquidity = [
            uint256(720_000 ether),
            610_000 ether,
            520_000 ether,
            460_000 ether,
            380_000 ether,
            340_000 ether,
            290_000 ether,
            250_000 ether,
            220_000 ether
        ];
        for (uint256 i; i < lenders.length; ++i) {
            cash.mint(lenders[i], liquidity[i]);
        }
        cash.renounceAdministration();
        vm.stopBroadcast();
    }
}
