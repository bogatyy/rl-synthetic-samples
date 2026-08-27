// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract AbecedarianRewardDispenser {
    constructor() payable {
        require(msg.value == 1 ether, "reward funding");
    }

    function receiveReward(int key) external {
        require(key == 2 + 2, "key");
        uint256 reward = address(this).balance;
        require(reward != 0, "reward collected");
        (bool sent,) = payable(msg.sender).call{value: reward}("");
        require(sent, "reward transfer");
    }
}
