// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./WillowRewards.sol";

contract WillowStakeRouter {
    address public immutable cash;
    address public immutable stake;
    address public immutable pair;
    address public immutable vault;

    constructor(address cash_, address stake_, address pair_, address vault_) {
        cash = cash_;
        stake = stake_;
        pair = pair_;
        vault = vault_;
    }

    function depositCash(uint256 cashAmount, uint256 minimumShares, address receiver)
        external
        returns (uint256 shares)
    {
        IERC20Like(cash).transferFrom(msg.sender, pair, cashAmount);
        uint256 stakeOut = LocalPair(pair).quoteOut(cash, cashAmount);
        LocalPair(pair).swap(0, stakeOut, address(this));
        IERC20Like(stake).approve(vault, stakeOut);
        shares = WillowStakeVault(vault).deposit(stakeOut, receiver);
        require(shares >= minimumShares, "minimum");
    }
}

contract WillowGateway {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public stakeAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public tradingPair;
    address public stakeVault;
    address public scheduler;
    address public stakeRouter;
    address public accountFactory;
    address public membership;

    function configure(
        address cash,
        address stake,
        address reserve,
        address bank,
        address pair,
        address vault,
        address scheduler_,
        address router,
        address factory,
        address membership_
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        stakeAsset = stake;
        protectedReserve = reserve;
        liquidityBank = bank;
        tradingPair = pair;
        stakeVault = vault;
        scheduler = scheduler_;
        stakeRouter = router;
        accountFactory = factory;
        membership = membership_;
        administrator = address(0);
    }
}
