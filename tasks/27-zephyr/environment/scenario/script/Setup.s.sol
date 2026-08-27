// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/ZephyrEpoch.sol";
import "../src/ZephyrProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        ZephyrEpochToken token = new ZephyrEpochToken();
        LocalToken cash = new LocalToken("Zephyr Settlement Cash", "CASH", 18);
        LocalPair pair = new LocalPair(address(cash), address(token));
        ZephyrEpochRewards rewards = new ZephyrEpochRewards(address(token));
        ZephyrLiquidityTreasury treasury = new ZephyrLiquidityTreasury(address(rewards));
        ZephyrAffiliateRegistry affiliates = new ZephyrAffiliateRegistry();
        rewards.configure(address(pair), address(treasury), address(affiliates));
        token.setMinter(address(rewards), true);
        cash.mint(address(pair), 3_000_000 ether);
        token.mint(address(pair), 3_000_000 ether);
        pair.sync();
        token.configure(address(cash), address(pair), address(rewards), address(treasury), address(affiliates));
        cash.renounceAdministration();
        token.renounceAdministration();
        vm.stopBroadcast();
    }
}
