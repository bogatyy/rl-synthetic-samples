// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./WillowTransfers.sol";

contract WillowRewardReserve {
    address public vault;

    function bind(address vault_) external {
        require(vault == address(0), "bound");
        vault = vault_;
    }

    function pay(address token, address receiver, uint256 amount) external {
        require(msg.sender == vault, "vault");
        IERC20Like(token).transfer(receiver, amount);
    }
}

contract WillowRewardScheduler {
    address public immutable vault;
    address public immutable cash;
    address public immutable bonus;
    uint64 public epoch;

    constructor(address vault_, address cash_, address bonus_) {
        vault = vault_;
        cash = cash_;
        bonus = bonus_;
    }

    function publish() external {
        require(epoch == 0, "published");
        epoch = uint64(block.number);
        WillowStakeVault(vault).notifyReward(cash, 20_000 ether);
        WillowStakeVault(vault).notifyReward(bonus, 15_000 ether);
    }
}

contract WillowStakeVault {
    address public immutable stakeAsset;
    address public immutable reserve;
    address public transferController;
    address public scheduler;
    uint256 public totalSupply;
    address[] public rewardTokens;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public globalIndex;
    mapping(address => mapping(address => uint256)) public indexDebt;
    mapping(address => mapping(address => uint256)) public accrued;

    constructor(address stake_, address reserve_, address[] memory rewards_) {
        stakeAsset = stake_;
        reserve = reserve_;
        rewardTokens = rewards_;
    }

    function bindScheduler(address scheduler_) external {
        require(scheduler == address(0), "bound");
        scheduler = scheduler_;
    }

    function bindTransferController(address controller_) external {
        require(transferController == address(0), "bound");
        transferController = controller_;
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        WillowTransferController(transferController)
            .beforeMove(msg.sender, receiver, balanceOf[msg.sender], balanceOf[receiver], this.transfer.selector);
        _move(msg.sender, receiver, amount);
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 amount) external returns (bool) {
        if (msg.sender != owner) {
            uint256 permitted = allowance[owner][msg.sender];
            if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - amount;
        }
        WillowTransferController(transferController)
            .beforeMove(owner, receiver, balanceOf[owner], balanceOf[receiver], this.transferFrom.selector);
        _move(owner, receiver, amount);
        return true;
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        require(amount != 0 && receiver != address(0), "deposit");
        _checkpoint(receiver);
        IERC20Like(stakeAsset).transferFrom(msg.sender, address(this), amount);
        shares = amount;
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 shares, address receiver) external returns (uint256 assets) {
        _checkpoint(msg.sender);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        assets = shares;
        IERC20Like(stakeAsset).transfer(receiver, assets);
    }

    function notifyReward(address token, uint256 amount) external {
        require(msg.sender == scheduler && _isReward(token), "scheduler");
        globalIndex[token] += amount * 1 ether / totalSupply;
    }

    function claimAll(address receiver) external returns (uint256[] memory rewards) {
        require(WillowTransferController(transferController).rewardEligible(msg.sender), "eligibility");
        _checkpoint(msg.sender);
        rewards = new uint256[](rewardTokens.length);
        for (uint256 i; i < rewardTokens.length; ++i) {
            address token = rewardTokens[i];
            uint256 amount = accrued[msg.sender][token];
            require(amount != 0, "no rewards");
            accrued[msg.sender][token] = 0;
            amount = amount * WillowTransferController(transferController).rewardBps(msg.sender) / 10_000;
            rewards[i] = amount;
            WillowRewardReserve(reserve).pay(token, receiver, amount);
        }
    }

    function checkpointFromController(address account, uint256 balanceBefore) external {
        require(msg.sender == transferController && balanceBefore == balanceOf[account], "controller");
        _checkpoint(account);
    }

    function _checkpoint(address account) private {
        for (uint256 i; i < rewardTokens.length; ++i) {
            address token = rewardTokens[i];
            uint256 index = globalIndex[token];
            uint256 previous = indexDebt[account][token];
            if (index > previous && balanceOf[account] != 0) {
                accrued[account][token] += balanceOf[account] * (index - previous) / 1 ether;
            }
            indexDebt[account][token] = index;
        }
    }

    function _move(address owner, address receiver, uint256 amount) private {
        require(receiver != address(0), "receiver");
        balanceOf[owner] -= amount;
        balanceOf[receiver] += amount;
    }

    function _isReward(address token) private view returns (bool) {
        for (uint256 i; i < rewardTokens.length; ++i) {
            if (rewardTokens[i] == token) return true;
        }
        return false;
    }
}
