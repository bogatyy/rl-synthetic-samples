// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./LanternMarket.sol";

contract LanternPositionBook {
    struct Position {
        uint128 debtShares;
        uint32 openedAt;
        uint8 marketClass;
        bool active;
    }

    address public administrator = msg.sender;
    address public gateway;
    address[] public accounts;
    mapping(address => Position) public positions;

    event PositionOpened(address indexed account, uint256 debtShares, uint8 marketClass);

    function bind(address gateway_) external {
        require(msg.sender == administrator && gateway == address(0), "administrator");
        gateway = gateway_;
    }

    function seed(address account, uint128 debtShares, uint8 marketClass) external {
        require(msg.sender == administrator && !positions[account].active, "seed");
        positions[account] = Position(debtShares, uint32(block.number), marketClass, true);
        accounts.push(account);
        emit PositionOpened(account, debtShares, marketClass);
    }

    function freeze() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    function reduce(address account, uint256 amount) external returns (uint256 paid) {
        require(msg.sender == gateway, "gateway");
        Position storage position = positions[account];
        require(position.active, "position");
        paid = amount > position.debtShares ? position.debtShares : amount;
        position.debtShares -= uint128(paid);
        if (position.debtShares == 0) position.active = false;
    }
}

contract LanternLendingReserve {
    address public immutable cash;
    address public gateway;

    constructor(address cash_) {
        cash = cash_;
    }

    function bind(address gateway_) external {
        require(gateway == address(0), "bound");
        gateway = gateway_;
    }

    function release(address receiver, uint256 amount) external {
        require(msg.sender == gateway, "gateway");
        IERC20Like(cash).transfer(receiver, amount);
    }
}

contract LanternCreditGateway {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public venueFactory;
    address public marketFactory;
    address public marketRegistry;
    address public positionBook;

    function configure(
        address cash,
        address reserve,
        address bank,
        address venues,
        address markets,
        address registry,
        address book
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = reserve;
        liquidityBank = bank;
        venueFactory = venues;
        marketFactory = markets;
        marketRegistry = registry;
        positionBook = book;
        administrator = address(0);
    }

    function crossDeleverage(address account, address market, uint256 amount, address receiver) external {
        require(LanternMarketRegistry(marketRegistry).approved(market), "market");
        address asset = LanternDeleverageMarket(market).asset();
        IERC20Like(asset).transferFrom(msg.sender, market, amount);
        LanternDeleverageMarket(market).recordDeposit(account, amount);
        uint256 quoted = LanternDeleverageMarket(market).previewRefund(amount);
        uint256 refund = LanternPositionBook(positionBook).reduce(account, quoted);
        LanternLendingReserve(protectedReserve).release(receiver, refund);
    }
}
