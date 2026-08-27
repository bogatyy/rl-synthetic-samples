// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./NimbusOracle.sol";

contract NimbusPositionBook {
    struct Position {
        uint128 collateral;
        uint128 debt;
        uint64 openedAt;
    }

    address public administrator = msg.sender;
    address public marginPool;
    mapping(address => Position) public positions;
    uint256 public positionCount;

    event PositionOpened(address indexed account, uint256 collateral, uint256 debt);

    function bind(address pool) external {
        require(msg.sender == administrator && marginPool == address(0), "administrator");
        marginPool = pool;
    }

    function seed(address account, uint128 collateral, uint128 debt) external {
        require(msg.sender == administrator && positions[account].openedAt == 0, "seed");
        positions[account] = Position(collateral, debt, uint64(block.number));
        ++positionCount;
        emit PositionOpened(account, collateral, debt);
    }

    function freeze() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function addCollateral(address account, uint256 amount) external {
        require(msg.sender == marginPool, "margin pool");
        Position storage position = positions[account];
        if (position.openedAt == 0) {
            position.openedAt = uint64(block.number);
            ++positionCount;
            emit PositionOpened(account, 0, 0);
        }
        position.collateral += uint128(amount);
    }

    function addDebt(address account, uint256 amount) external {
        require(msg.sender == marginPool, "margin pool");
        positions[account].debt += uint128(amount);
    }

    function close(address account) external returns (uint256 collateral, uint256 debt) {
        require(msg.sender == marginPool, "margin pool");
        Position memory position = positions[account];
        require(position.debt != 0, "position");
        collateral = position.collateral;
        debt = position.debt;
        delete positions[account];
    }
}

contract NimbusMarginPool {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public collateralAsset;
    address public protectedReserve;
    address public oracle;
    address public positionBook;
    uint16 public collateralFactorBps;
    uint16 public liquidationBps;
    mapping(address => uint256) public liquidatedNotional;

    event CollateralDeposited(address indexed account, uint256 amount);
    event Borrowed(address indexed account, address indexed receiver, uint256 amount);
    event Liquidated(address indexed account, address indexed liquidator, uint256 debt, uint256 collateral);
    event MarketConfigured(address indexed oracle, address indexed positionBook);

    function configure(address cash, address collateral, address oracle_, address book) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        collateralAsset = collateral;
        protectedReserve = address(this);
        oracle = oracle_;
        positionBook = book;
        collateralFactorBps = 8_000;
        liquidationBps = 11_200;
        emit MarketConfigured(oracle_, book);
    }

    function freeze() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function depositCollateral(uint256 amount, address account) external {
        require(amount != 0, "amount");
        IERC20Like(collateralAsset).transferFrom(msg.sender, address(this), amount);
        NimbusPositionBook(positionBook).addCollateral(account, amount);
        emit CollateralDeposited(account, amount);
    }

    function borrow(uint256 amount, address receiver) external {
        (uint128 collateral, uint128 debt,) = NimbusPositionBook(positionBook).positions(msg.sender);
        uint256 activityLimit = liquidatedNotional[msg.sender] * 11 / 4;
        require(activityLimit != 0 && uint256(debt) + amount <= activityLimit, "margin tier");
        uint256 capacity = uint256(collateral) * NimbusCompositeOracle(oracle).price() / 1 ether;
        capacity = capacity * collateralFactorBps / 10_000;
        require(uint256(debt) + amount <= capacity, "health");
        NimbusPositionBook(positionBook).addDebt(msg.sender, amount);
        IERC20Like(settlementAsset).transfer(receiver, amount);
        emit Borrowed(msg.sender, receiver, amount);
    }

    function liquidate(address account) external {
        (uint128 collateral, uint128 debt,) = NimbusPositionBook(positionBook).positions(account);
        uint256 value = uint256(collateral) * NimbusCompositeOracle(oracle).price() / 1 ether;
        require(value * 10_000 < uint256(debt) * liquidationBps, "healthy");
        (uint256 collateralOut, uint256 debtIn) = NimbusPositionBook(positionBook).close(account);
        IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), debtIn);
        IERC20Like(collateralAsset).transfer(msg.sender, collateralOut);
        liquidatedNotional[msg.sender] += debtIn;
        emit Liquidated(account, msg.sender, debtIn, collateralOut);
    }
}
