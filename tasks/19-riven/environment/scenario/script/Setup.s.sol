// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/RivenPool.sol";
import "../src/RivenProtocol.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        RivenBatchVault vault = new RivenBatchVault();
        LocalToken derivative = new LocalToken("Riven Principal Note", "rNOTE", 18);
        LocalToken cash = new LocalToken("Riven Settlement Cash", "CASH", 18);
        RivenPoolShare share = new RivenPoolShare(address(vault), "rvBPT", 99_900_000 ether);
        RivenRateCache rates = new RivenRateCache();
        rates.configure(address(derivative), 1_183_700_000_000_000_000, 30 days);
        rates.configure(address(cash), 1 ether, 30 days);

        address[3] memory assets = [address(derivative), address(share), address(cash)];
        uint256[3] memory scales = [uint256(1 ether), uint256(1 ether), uint256(1 ether)];
        RivenComposablePool pool =
            new RivenComposablePool(address(vault), address(rates), address(share), assets, scales, 1_200_000, 1e14);
        address[] memory loanAssets = new address[](2);
        loanAssets[0] = address(derivative);
        loanAssets[1] = address(cash);
        MultiFlashBank lender = new MultiFlashBank(loanAssets, 5);

        uint256[3] memory initial = [uint256(8_000_000 ether), uint256(90_000_000 ether), uint256(8_000_000 ether)];
        derivative.mint(address(vault), initial[0]);
        cash.mint(address(vault), initial[2]);
        vault.registerPool(address(pool), initial);
        derivative.mint(address(lender), 12_000_000 ether);
        cash.mint(address(lender), 3_000_000 ether);
        vault.configure(address(cash), address(lender));
        rates.finishConfiguration();
        derivative.renounceAdministration();
        cash.renounceAdministration();
        vm.stopBroadcast();
    }
}
