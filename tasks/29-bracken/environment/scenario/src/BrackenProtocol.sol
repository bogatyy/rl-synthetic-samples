// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./BrackenPolicy.sol";
import "./BrackenStrategies.sol";

contract BrackenPortfolioVault {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public bondAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public accountant;
    address public bondStrategy;
    address public desk;
    address public withdrawalPolicy;
    address[] public withdrawalQueue;
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;

    function configure(
        address cash,
        address bond,
        address bank,
        address accountant_,
        address bondStrategy_,
        address desk_,
        address policy_,
        address[] calldata queue
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        bondAsset = bond;
        protectedReserve = address(this);
        liquidityBank = bank;
        accountant = accountant_;
        bondStrategy = bondStrategy_;
        desk = desk_;
        withdrawalPolicy = policy_;
        withdrawalQueue = queue;
        administrator = address(0);
    }

    function bootstrap(uint256 amount, uint256 cashAllocation, uint256 queuedAllocation, address receiver) external {
        require(totalShares == 0 && cashAllocation + queuedAllocation < amount, "bootstrap");
        IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), amount);
        IERC20Like(settlementAsset).transfer(withdrawalQueue[0], cashAllocation);
        IERC20Like(settlementAsset).transfer(withdrawalQueue[1], queuedAllocation);
        totalShares = amount;
        balanceOf[receiver] = amount;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20Like(settlementAsset).balanceOf(address(this)) + BrackenAccountant(accountant).totalReported();
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        uint256 assetsBefore = totalAssets();
        shares = amount * totalShares / assetsBefore;
        IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), amount);
        totalShares += shares;
        balanceOf[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        require(BrackenWithdrawalPolicy(withdrawalPolicy).cleared(msg.sender), "withdrawal plan");
        assets = shares * totalAssets() / totalShares;
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        _ensureCash(assets);
        IERC20Like(settlementAsset).transfer(receiver, assets);
    }

    function _ensureCash(uint256 amount) private {
        uint256 available = IERC20Like(settlementAsset).balanceOf(address(this));
        for (uint256 i; available < amount && i < withdrawalQueue.length; ++i) {
            available += IBrackenStrategy(withdrawalQueue[i]).liquidate(amount - available, address(this));
        }
        require(available >= amount, "liquidity");
    }
}
