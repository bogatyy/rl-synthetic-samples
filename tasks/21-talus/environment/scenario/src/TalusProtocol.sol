// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface ITalusMovementObserver {
    function onCampaignMovement(address from, address to, uint256 amount) external;
    function onHashrateMovement(address from, address to, uint256 amount) external;
}

contract TalusHashrateToken is LocalToken {
    address public rewards;

    constructor() LocalToken("Talus Mining Hashrate", "THR", 18) {}

    function configure(address rewards_) external {
        require(msg.sender == administrator && rewards == address(0), "configuration");
        rewards = rewards_;
    }

    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (rewards != address(0)) ITalusMovementObserver(rewards).onHashrateMovement(from, to, amount);
    }
}

contract TalusCampaignToken is LocalToken {
    address public settlementAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public rewards;
    address public liquidityCoordinator;
    address public referralBook;
    address public hashrateAsset;

    constructor() LocalToken("Talus Campaign Credit", "TAL", 18) {}

    function configure(
        address cash,
        address pair,
        address bank,
        address rewards_,
        address coordinator,
        address referrals,
        address hashrate
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = pair;
        liquidityBank = bank;
        rewards = rewards_;
        liquidityCoordinator = coordinator;
        referralBook = referrals;
        hashrateAsset = hashrate;
    }

    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (rewards != address(0)) ITalusMovementObserver(rewards).onCampaignMovement(from, to, amount);
    }
}
