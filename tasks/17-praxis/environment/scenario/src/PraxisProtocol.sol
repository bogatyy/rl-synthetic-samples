// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./PraxisStrategy.sol";

contract PraxisLeveragedLiquidity {
    struct Account {
        uint128 cashCollateral;
        uint128 shareCollateral;
        uint128 cashDebt;
    }

    address public administrator = msg.sender;
    address public settlementAsset;
    address public baseAsset;
    address public protectedReserve;
    address public liquidityBank;
    address[] private liquiditySources;
    address public strategy;
    address public rangePool;
    address public coordinator;
    address public rateOracle;
    mapping(address => Account) public accounts;

    event Deposit(address indexed account, address indexed asset, uint256 amount);
    event Borrow(address indexed account, address indexed asset, uint256 amount, address receiver);
    event FacilityConfigured(address indexed strategy, address indexed rateOracle, address[] liquiditySources);

    function configure(
        address cash,
        address base,
        address[] calldata banks,
        address strategy_,
        address rangePool_,
        address coordinator_,
        address oracle
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        require(banks.length == 4, "liquidity sources");
        settlementAsset = cash;
        baseAsset = base;
        protectedReserve = address(this);
        liquidityBank = banks[0];
        for (uint256 i; i < banks.length; ++i) {
            liquiditySources.push(banks[i]);
        }
        strategy = strategy_;
        rangePool = rangePool_;
        coordinator = coordinator_;
        rateOracle = oracle;
        administrator = address(0);
        emit FacilityConfigured(strategy_, oracle, banks);
    }

    function liquiditySourceCount() external view returns (uint256) {
        return liquiditySources.length;
    }

    function liquiditySourceAt(uint256 index) external view returns (address) {
        return liquiditySources[index];
    }

    function depositCash(uint256 amount) external {
        IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), amount);
        accounts[msg.sender].cashCollateral += uint128(amount);
        emit Deposit(msg.sender, settlementAsset, amount);
    }

    function depositStrategyShares(uint256 amount) external {
        PraxisStrategyShare(strategy).transferFrom(msg.sender, address(this), amount);
        accounts[msg.sender].shareCollateral += uint128(amount);
        emit Deposit(msg.sender, strategy, amount);
    }

    function borrowCash(uint256 amount, address receiver) external {
        Account storage account = accounts[msg.sender];
        uint256 value = uint256(account.shareCollateral) * IPraxisRateSource(rateOracle).cachedRate() / 1 ether;
        require(uint256(account.cashDebt) + amount <= value * 7_500 / 10_000, "share collateral");
        account.cashDebt += uint128(amount);
        IERC20Like(settlementAsset).transfer(receiver, amount);
        emit Borrow(msg.sender, settlementAsset, amount, receiver);
    }
}
