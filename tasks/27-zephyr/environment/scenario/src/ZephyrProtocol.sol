// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./ZephyrEpoch.sol";

contract ZephyrEpochToken is LocalToken {
    address public settlementAsset;
    address public protectedReserve;
    address public epochRewards;
    address public treasury;
    address public affiliates;

    constructor() LocalToken("Zephyr Membership Credit", "ZEP", 18) {}

    function configure(address cash, address pair, address rewards, address treasury_, address affiliates_) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = pair;
        epochRewards = rewards;
        treasury = treasury_;
        affiliates = affiliates_;
    }

    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (epochRewards != address(0)) IZephyrMovement(epochRewards).observe(from, to, amount);
    }
}
