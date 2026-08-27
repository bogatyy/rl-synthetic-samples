// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./PraxisRange.sol";

contract PraxisStrategyShare is IPraxisMintCallback {
    string public constant name = "Praxis Range Strategy";
    string public constant symbol = "PRS";
    uint8 public constant decimals = 18;
    address public immutable cash;
    address public immutable base;
    address public immutable rangePool;
    address public coordinator;
    uint256 public basePosition;
    uint256[] public managedPositions;
    uint256 public totalSupply;
    uint256 public accountedAssets;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address cash_, address base_, address rangePool_) {
        cash = cash_;
        base = base_;
        rangePool = rangePool_;
    }

    function initialize(uint128 cashAmount, uint128 baseAmount, address receiver) external {
        require(totalSupply == 0, "initialized");
        basePosition = PraxisRangePool(rangePool).mint(-600, 600, cashAmount, baseAmount);
        managedPositions.push(basePosition);
        totalSupply = cashAmount;
        accountedAssets = cashAmount;
        balanceOf[receiver] = cashAmount;
    }

    function bindCoordinator(address coordinator_) external {
        require(coordinator == address(0), "bound");
        coordinator = coordinator_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[receiver] += amount;
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[owner][msg.sender];
        if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - amount;
        balanceOf[owner] -= amount;
        balanceOf[receiver] += amount;
        return true;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * accountedAssets / totalSupply;
    }

    function deposit(uint128 cashAmount, uint128 baseAmount, address receiver) external returns (uint256 shares) {
        require(cashAmount != 0 && baseAmount != 0 && receiver != address(0), "deposit");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(base).transferFrom(msg.sender, address(this), baseAmount);
        uint256 contribution = (uint256(cashAmount) + uint256(baseAmount)) / 2;
        shares = contribution * totalSupply / accountedAssets;
        require(shares != 0, "shares");
        uint256 positionId = PraxisRangePool(rangePool).mint(-600, 600, cashAmount, baseAmount);
        managedPositions.push(positionId);
        totalSupply += shares;
        accountedAssets += contribution;
        balanceOf[receiver] += shares;
    }

    function compound(uint256 releasedCash) external {
        require(msg.sender == coordinator, "coordinator");
        accountedAssets += releasedCash;
    }

    function onPraxisMint(address pool, address cash_, address base_, uint256 cashAmount, uint256 baseAmount) external {
        require(msg.sender == rangePool && pool == rangePool && cash_ == cash && base_ == base, "pool");
        IERC20Like(cash).transfer(pool, cashAmount);
        IERC20Like(base).transfer(pool, baseAmount);
    }
}

contract PraxisYieldEscrow {
    address public immutable cash;
    address public strategy;
    uint256 public nextTranche;
    uint256 public immutable trancheSize;

    constructor(address cash_, uint256 trancheSize_) {
        cash = cash_;
        trancheSize = trancheSize_;
    }

    function bind(address strategy_) external {
        require(strategy == address(0), "bound");
        strategy = strategy_;
    }

    function release(uint256 tranche) external returns (uint256 amount) {
        require(tranche == nextTranche && tranche < 7, "tranche");
        nextTranche = tranche + 1;
        amount = trancheSize;
        IERC20Like(cash).transfer(strategy, amount);
    }
}

contract PraxisRateOracle {
    address public administrator = msg.sender;
    address public immutable strategy;
    address public coordinator;
    uint256 public cachedRate = 1 ether;
    uint64 public observations;
    uint256[7] public samples;

    event ConsumerRegistered(address indexed consumer);

    constructor(address strategy_) {
        strategy = strategy_;
        for (uint256 i; i < 7; ++i) {
            samples[i] = 1 ether;
        }
    }

    function bind(address coordinator_) external {
        require(msg.sender == administrator && coordinator == address(0), "bound");
        coordinator = coordinator_;
    }

    function registerConsumer(address consumer) external {
        require(msg.sender == administrator && consumer != address(0), "administrator");
        administrator = address(0);
        emit ConsumerRegistered(consumer);
    }

    function sync() external {
        require(msg.sender == coordinator, "coordinator");
        uint256 observed = PraxisStrategyShare(strategy).convertToAssets(1 ether);
        samples[observations % 7] = observed;
        observations += 1;
        uint256[7] memory ordered = samples;
        for (uint256 i = 1; i < 7; ++i) {
            uint256 value = ordered[i];
            uint256 j = i;
            while (j != 0 && ordered[j - 1] > value) {
                ordered[j] = ordered[j - 1];
                --j;
            }
            ordered[j] = value;
        }
        cachedRate = ordered[3];
    }
}

interface IPraxisRateSource {
    function cachedRate() external view returns (uint256);
}

interface IPraxisDebtView {
    function accounts(address account)
        external
        view
        returns (uint128 cashCollateral, uint128 shareCollateral, uint128 cashDebt);
}

contract PraxisPortfolioOracle {
    struct Source {
        address oracle;
        uint16 weight;
    }

    address public administrator = msg.sender;
    address public consumer;
    Source[] public sources;

    event SourceRegistered(address indexed oracle, uint256 indexed index, uint16 weight);
    event ConsumerRegistered(address indexed consumer);

    constructor(address[] memory oracles, uint16[] memory weights) {
        require(oracles.length == 21 && weights.length == oracles.length, "sources");
        for (uint256 i; i < oracles.length; ++i) {
            require(oracles[i] != address(0) && weights[i] != 0, "source");
            sources.push(Source(oracles[i], weights[i]));
            emit SourceRegistered(oracles[i], i, weights[i]);
        }
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function registerConsumer(address consumer_) external {
        require(msg.sender == administrator && consumer_ != address(0), "administrator");
        consumer = consumer_;
        administrator = address(0);
        emit ConsumerRegistered(consumer_);
    }

    function cachedRate() external view returns (uint256) {
        uint256 count = sources.length;
        uint256[] memory values = new uint256[](count);
        uint256[] memory weights = new uint256[](count);
        uint256 totalWeight;
        for (uint256 i; i < count; ++i) {
            Source memory source = sources[i];
            values[i] = IPraxisRateSource(source.oracle).cachedRate();
            weights[i] = source.weight;
            totalWeight += source.weight;
        }
        for (uint256 i = 1; i < count; ++i) {
            uint256 value = values[i];
            uint256 weight = weights[i];
            uint256 j = i;
            while (j != 0 && values[j - 1] > value) {
                values[j] = values[j - 1];
                weights[j] = weights[j - 1];
                --j;
            }
            values[j] = value;
            weights[j] = weight;
        }
        uint256 cumulative;
        for (uint256 i; i < count; ++i) {
            cumulative += weights[i];
            if (cumulative * 2 >= totalWeight) return values[i];
        }
        revert("median");
    }
}

contract PraxisCompoundingCoordinator {
    address public immutable rangePool;
    address public immutable strategy;
    address public immutable escrow;
    address public immutable oracle;
    uint128 public immutable minimumCash;
    uint128 public immutable minimumBase;
    address public lender;
    mapping(uint256 => uint8) public nextPositionTranche;

    constructor(
        address rangePool_,
        address strategy_,
        address escrow_,
        address oracle_,
        uint128 minimumCash_,
        uint128 minimumBase_
    ) {
        rangePool = rangePool_;
        strategy = strategy_;
        escrow = escrow_;
        oracle = oracle_;
        minimumCash = minimumCash_;
        minimumBase = minimumBase_;
    }

    function bindLender(address lender_) external {
        require(lender == address(0) && lender_ != address(0), "bound");
        lender = lender_;
    }

    function roll(uint256 positionId, uint256 tranche) external {
        (address owner, uint128 cashAmount, uint128 baseAmount, int24 lower, int24 upper) =
            PraxisRangePool(rangePool).positions(positionId);
        int24 tick = PraxisRangePool(rangePool).currentTick();
        require(owner == msg.sender && lower < tick && tick < upper, "position");
        require(cashAmount >= minimumCash && baseAmount >= minimumBase, "liquidity");
        require(nextPositionTranche[positionId] == tranche, "tranche order");
        nextPositionTranche[positionId] = uint8(tranche + 1);
        if (tranche == 0) PraxisRangePool(rangePool).lockPosition(positionId);
        uint256 released = PraxisYieldEscrow(escrow).release(tranche);
        PraxisStrategyShare(strategy).compound(released);
        PraxisRateOracle(oracle).sync();
    }

    function canUnlock(address owner) external view returns (bool) {
        (,, uint128 debt) = IPraxisDebtView(lender).accounts(owner);
        return debt != 0;
    }
}
