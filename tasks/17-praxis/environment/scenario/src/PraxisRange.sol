// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IPraxisMintCallback {
    function onPraxisMint(address pool, address cash, address base, uint256 cashAmount, uint256 baseAmount) external;
}

interface IPraxisPositionLocker {
    function canUnlock(address owner) external view returns (bool);
}

contract PraxisRangePool {
    struct Position {
        address owner;
        uint128 cashAmount;
        uint128 baseAmount;
        int24 lower;
        int24 upper;
    }

    address public immutable cash;
    address public immutable base;
    uint112 public cashReserve;
    uint112 public baseReserve;
    int24 public currentTick;
    address public coordinator;
    uint256 public nextId = 1;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => address) public positionLocker;
    bool private mintEntered;

    constructor(address cash_, address base_) {
        cash = cash_;
        base = base_;
    }

    function bindCoordinator(address coordinator_) external {
        require(coordinator == address(0) && coordinator_ != address(0), "bound");
        coordinator = coordinator_;
    }

    function seed(uint256 cashAmount, uint256 baseAmount) external {
        require(cashReserve == 0 && baseReserve == 0, "seeded");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(base).transferFrom(msg.sender, address(this), baseAmount);
        _sync();
    }

    function mint(int24 lower, int24 upper, uint128 cashAmount, uint128 baseAmount) external returns (uint256 id) {
        require(!mintEntered, "mint callback");
        mintEntered = true;
        require(lower < currentTick && currentTick < upper, "range");
        uint256 cashBefore = IERC20Like(cash).balanceOf(address(this));
        uint256 baseBefore = IERC20Like(base).balanceOf(address(this));
        IPraxisMintCallback(msg.sender).onPraxisMint(address(this), cash, base, cashAmount, baseAmount);
        require(
            IERC20Like(cash).balanceOf(address(this)) >= cashBefore + cashAmount
                && IERC20Like(base).balanceOf(address(this)) >= baseBefore + baseAmount,
            "callback funding"
        );
        id = nextId++;
        positions[id] = Position(msg.sender, cashAmount, baseAmount, lower, upper);
        _sync();
        mintEntered = false;
    }

    function transferPosition(uint256 id, address receiver) external {
        require(positions[id].owner == msg.sender && receiver != address(0), "owner");
        positions[id].owner = receiver;
    }

    function lockPosition(uint256 id) external {
        require(msg.sender == coordinator && positions[id].owner != address(0), "coordinator");
        if (positionLocker[id] == address(0)) positionLocker[id] = msg.sender;
    }

    function burn(uint256 id, address receiver) external returns (uint256 cashOut, uint256 baseOut) {
        Position memory position = positions[id];
        require(position.owner == msg.sender, "owner");
        address locker = positionLocker[id];
        require(locker == address(0) || IPraxisPositionLocker(locker).canUnlock(msg.sender), "position locked");
        delete positions[id];
        delete positionLocker[id];
        cashOut = position.cashAmount;
        baseOut = position.baseAmount;
        IERC20Like(cash).transfer(receiver, cashOut);
        IERC20Like(base).transfer(receiver, baseOut);
        _sync();
    }

    function swapCashForBase(uint256 cashIn, uint256 minimumBase, address receiver) external returns (uint256 baseOut) {
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashIn);
        uint256 amountWithFee = cashIn * 9_970;
        baseOut = amountWithFee * baseReserve / (uint256(cashReserve) * 10_000 + amountWithFee);
        require(baseOut >= minimumBase && baseOut < baseReserve, "output");
        IERC20Like(base).transfer(receiver, baseOut);
        _sync();
        currentTick += int24(int256(cashIn / 25_000 ether));
    }

    function _sync() private {
        uint256 c = IERC20Like(cash).balanceOf(address(this));
        uint256 b = IERC20Like(base).balanceOf(address(this));
        require(c <= type(uint112).max && b <= type(uint112).max, "reserve");
        cashReserve = uint112(c);
        baseReserve = uint112(b);
    }
}
