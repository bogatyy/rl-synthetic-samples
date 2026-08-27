// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IQuartzMintCallback {
    function onQuartzMint(address engine, address cash, address quote, uint256 cashAmount, uint256 quoteAmount) external;
}

contract QuartzRangeVenue {
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant ACTIVE_LIQUIDITY = 1_000 ether;
    address public immutable cash;
    address public immutable quote;
    uint112 public cashReserve;
    uint112 public quoteReserve;
    uint256 public feeGrowth;
    int24 public currentTick;

    constructor(address cash_, address quote_) {
        cash = cash_;
        quote = quote_;
    }

    function seed(uint256 cashAmount, uint256 quoteAmount) external {
        require(cashReserve == 0 && quoteReserve == 0, "seeded");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(quote).transferFrom(msg.sender, address(this), quoteAmount);
        _sync();
    }

    function exchange(address tokenIn, uint256 amountIn, uint256 minimumOut, address receiver)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn == cash || tokenIn == quote, "token");
        bool cashIn = tokenIn == cash;
        uint256 reserveIn = cashIn ? cashReserve : quoteReserve;
        uint256 reserveOut = cashIn ? quoteReserve : cashReserve;
        IERC20Like(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountWithFee = amountIn * 9_970;
        amountOut = amountWithFee * reserveOut / (reserveIn * 10_000 + amountWithFee);
        require(amountOut >= minimumOut && amountOut < reserveOut, "output");
        IERC20Like(cashIn ? quote : cash).transfer(receiver, amountOut);
        uint256 paidFee = amountIn * 30 / 10_000;
        feeGrowth += paidFee * Q128 / ACTIVE_LIQUIDITY;
        int24 movement = int24(int256(amountIn / 50_000 ether));
        currentTick = cashIn ? currentTick + movement : currentTick - movement;
        _sync();
    }

    function _sync() private {
        uint256 c = IERC20Like(cash).balanceOf(address(this));
        uint256 q = IERC20Like(quote).balanceOf(address(this));
        require(c <= type(uint112).max && q <= type(uint112).max, "reserves");
        cashReserve = uint112(c);
        quoteReserve = uint112(q);
    }
}

contract QuartzPositionEngine {
    struct Position {
        address owner;
        uint128 cashAmount;
        uint128 quoteAmount;
        uint128 liquidity;
        int24 lower;
        int24 upper;
        uint256 feeCheckpoint;
    }

    address public immutable cash;
    address public immutable quote;
    address public immutable venue;
    uint256 public nextId = 1;
    mapping(uint256 => Position) public positions;

    constructor(address cash_, address quote_, address venue_) {
        cash = cash_;
        quote = quote_;
        venue = venue_;
    }

    function mint(int24 lower, int24 upper, uint128 cashAmount, uint128 quoteAmount) external returns (uint256 id) {
        require(lower < upper && upper - lower >= 160 && upper - lower <= 800, "range");
        uint256 cashBefore = IERC20Like(cash).balanceOf(address(this));
        uint256 quoteBefore = IERC20Like(quote).balanceOf(address(this));
        IQuartzMintCallback(msg.sender).onQuartzMint(address(this), cash, quote, cashAmount, quoteAmount);
        require(
            IERC20Like(cash).balanceOf(address(this)) >= cashBefore + cashAmount
                && IERC20Like(quote).balanceOf(address(this)) >= quoteBefore + quoteAmount,
            "callback"
        );
        uint256 width = uint24(upper - lower);
        uint256 liquidity = (uint256(cashAmount) + uint256(quoteAmount)) * 10_000 / width;
        id = nextId++;
        positions[id] = Position(
            msg.sender, cashAmount, quoteAmount, uint128(liquidity), lower, upper, QuartzRangeVenue(venue).feeGrowth()
        );
    }

    function transferPosition(uint256 id, address receiver) external {
        require(positions[id].owner == msg.sender && receiver != address(0), "owner");
        positions[id].owner = receiver;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return positions[id].owner;
    }

    function value(uint256 id) external view returns (uint256) {
        Position memory position = positions[id];
        uint256 growth = QuartzRangeVenue(venue).feeGrowth() - position.feeCheckpoint;
        uint256 accrued = uint256(position.liquidity) * growth >> 128;
        return uint256(position.cashAmount) + uint256(position.quoteAmount) + accrued;
    }
}
