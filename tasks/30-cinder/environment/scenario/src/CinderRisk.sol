// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./CinderOracle.sol";

interface IWrappedReserveValue {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract CreditPolicy {
    struct Market {
        uint128 debtPrice;
        uint128 cashExposureCap;
        uint16 collateralFactorBps;
        uint16 liquidationFactorBps;
        uint32 listedBlock;
        uint16 accountCap;
        bool debtEnabled;
        bool listed;
    }

    address public administrator = msg.sender;
    address public immutable priceBook;
    address private pool;
    mapping(address => Market) public markets;

    event PolicyBound(address indexed pool);
    event MarketListed(
        address indexed wrapper,
        address indexed underlying,
        uint256 debtPrice,
        uint256 accountCap,
        uint256 cashExposureCap
    );

    constructor(address priceBook_) {
        priceBook = priceBook_;
    }

    function bind(address pool_) external {
        require(msg.sender == administrator && pool == address(0), "configuration");
        pool = pool_;
        emit PolicyBound(pool_);
    }

    function list(
        address wrapper,
        uint16 collateralFactorBps,
        uint16 liquidationFactorBps,
        uint16 accountCap,
        uint128 cashExposureCap,
        bool debtEnabled
    ) external {
        require(msg.sender == administrator, "administrator");
        require(
            collateralFactorBps <= 9_900 && liquidationFactorBps >= collateralFactorBps
                && liquidationFactorBps <= 10_000 && accountCap != 0 && cashExposureCap != 0,
            "factors"
        );
        address underlying = IWrappedReserveValue(wrapper).asset();
        uint256 debtPrice = CinderPriceBook(priceBook).valueInCash(wrapper, 1 ether);
        require(debtPrice != 0 && debtPrice <= type(uint128).max, "price");
        markets[wrapper] = Market(
            uint128(debtPrice),
            cashExposureCap,
            collateralFactorBps,
            liquidationFactorBps,
            uint32(block.number),
            accountCap,
            debtEnabled,
            true
        );
        emit MarketListed(wrapper, underlying, debtPrice, accountCap, cashExposureCap);
    }

    function finishConfiguration() external {
        require(msg.sender == administrator && pool != address(0), "administrator");
        administrator = address(0);
    }

    function collateralCapacity(address wrapper, uint256 shares) external view returns (uint256) {
        Market memory market = markets[wrapper];
        require(market.listed, "market");
        uint256 currentValue = CinderPriceBook(priceBook).valueInCash(wrapper, shares);
        return currentValue * market.collateralFactorBps / 10_000;
    }

    function isListed(address wrapper) external view returns (bool) {
        return markets[wrapper].listed;
    }

    function marketLimits(address wrapper) external view returns (uint256 accountCap, uint256 cashExposureCap) {
        Market memory market = markets[wrapper];
        require(market.listed, "market");
        return (market.accountCap, market.cashExposureCap);
    }

    function wrapperDebtValue(address wrapper, uint256 shares) external view returns (uint256) {
        Market memory market = markets[wrapper];
        require(market.listed && market.debtEnabled, "wrapper debt disabled");
        return shares * market.debtPrice / 1 ether;
    }

    function wrapperDebtEnabled(address wrapper) external view returns (bool) {
        return markets[wrapper].listed && markets[wrapper].debtEnabled;
    }
}
