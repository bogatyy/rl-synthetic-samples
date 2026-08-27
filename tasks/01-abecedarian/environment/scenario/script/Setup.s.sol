// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/AbecedarianRewardDispenser.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        new AbecedarianRewardDispenser{value: 1 ether}();
        vm.stopBroadcast();
    }
}
