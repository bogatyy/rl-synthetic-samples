// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IBrackenStrategy {
    function reportedValue() external view returns (uint256);
    function liquidate(uint256 amount, address receiver) external returns (uint256 released);
}

contract BrackenCashStrategy is IBrackenStrategy {
    address public immutable cash;
    address public vault;

    constructor(address cash_) {
        cash = cash_;
    }

    function bind(address vault_) external {
        require(vault == address(0), "bound");
        vault = vault_;
    }

    function reportedValue() external view returns (uint256) {
        return IERC20Like(cash).balanceOf(address(this));
    }

    function liquidate(uint256 amount, address receiver) external returns (uint256 released) {
        require(msg.sender == vault, "vault");
        uint256 balance = IERC20Like(cash).balanceOf(address(this));
        released = amount > balance ? balance : amount;
        IERC20Like(cash).transfer(receiver, released);
    }
}

contract BrackenQueuedStrategy is IBrackenStrategy {
    address public immutable cash;
    address public vault;
    uint256 public queuedDebt;

    constructor(address cash_) {
        cash = cash_;
    }

    function bind(address vault_) external {
        require(vault == address(0), "bound");
        vault = vault_;
    }

    function setQueuedDebt(uint256 amount) external {
        require(msg.sender == vault, "vault");
        queuedDebt = amount;
    }

    function reportedValue() external view returns (uint256) {
        return IERC20Like(cash).balanceOf(address(this)) + queuedDebt;
    }

    function liquidate(uint256 amount, address receiver) external returns (uint256 released) {
        require(msg.sender == vault, "vault");
        uint256 balance = IERC20Like(cash).balanceOf(address(this));
        released = amount > balance ? balance : amount;
        IERC20Like(cash).transfer(receiver, released);
    }
}

contract BrackenBondStrategy is IBrackenStrategy {
    address public immutable cash;
    address public immutable bond;
    address public vault;
    uint256 public accountedBond;
    uint256 public constant REPORT_MULTIPLIER = 30;

    constructor(address cash_, address bond_) {
        cash = cash_;
        bond = bond_;
    }

    function bind(address vault_) external {
        require(vault == address(0), "bound");
        vault = vault_;
    }

    function depositBond(uint256 amount) external {
        require(msg.sender == vault, "vault");
        IERC20Like(bond).transferFrom(msg.sender, address(this), amount);
        accountedBond += amount;
    }

    function reportedValue() external view returns (uint256) {
        return IERC20Like(bond).balanceOf(address(this)) * 1e12 * REPORT_MULTIPLIER;
    }

    function liquidate(uint256, address) external pure returns (uint256 released) {
        return 0;
    }
}

contract BrackenAccountant {
    address[] public strategies;

    constructor(address[] memory strategies_) {
        strategies = strategies_;
    }

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function totalReported() external view returns (uint256 total) {
        for (uint256 i; i < strategies.length; ++i) {
            total += IBrackenStrategy(strategies[i]).reportedValue();
        }
    }
}

contract BrackenFixedDesk {
    address public immutable cash;
    address public immutable bond;

    constructor(address cash_, address bond_) {
        cash = cash_;
        bond = bond_;
    }

    function buyExactBond(uint256 bondAmount, uint256 maximumCash, address receiver)
        external
        returns (uint256 cashAmount)
    {
        cashAmount = bondAmount * 1e12;
        require(cashAmount <= maximumCash, "maximum");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(bond).transfer(receiver, bondAmount);
    }
}
