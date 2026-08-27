// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./KestrelDebt.sol";

contract KestrelEntry {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public debtLedger;
    address public instrumentRegistry;
    address public advisor;
    address public accountingRouter;
    address[3] private paymentAssets;
    address[3] private conversionVenues;

    event SystemConfigured(address indexed reserve, address indexed ledger, address indexed accounting);

    function configure(
        address cash,
        address reserve,
        address bank,
        address ledger,
        address registry,
        address advisor_,
        address accounting,
        address[3] calldata payments,
        address[3] calldata venues
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = reserve;
        liquidityBank = bank;
        debtLedger = ledger;
        instrumentRegistry = registry;
        advisor = advisor_;
        accountingRouter = accounting;
        paymentAssets = payments;
        conversionVenues = venues;
        administrator = address(0);
        emit SystemConfigured(reserve, ledger, accounting);
    }

    function paymentAsset(uint256 index) external view returns (address) {
        return paymentAssets[index];
    }

    function conversionVenue(uint256 index) external view returns (address) {
        return conversionVenues[index];
    }
}

contract KestrelAllocationVault {
    address public immutable cash;
    address public immutable ledger;
    address public immutable advisor;
    address public immutable accountingRouter;
    address public activeStrategy;
    uint256 public totalShares;
    uint256 public accountedAssets;
    uint256 public lastMigrationBlock;
    mapping(address => uint256) public balanceOf;

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event StrategyMigrated(address indexed previous, address indexed next, uint256 released, uint256 assets);

    constructor(address cash_, address ledger_, address advisor_, address accountingRouter_, address strategy_) {
        cash = cash_;
        ledger = ledger_;
        advisor = advisor_;
        accountingRouter = accountingRouter_;
        activeStrategy = strategy_;
    }

    function bootstrap(uint256 amount, uint256 invested, address receiver) external {
        require(totalShares == 0 && invested < amount && receiver != address(0), "bootstrapped");
        require(IERC20Like(cash).transferFrom(msg.sender, address(this), amount), "transfer");
        require(IERC20Like(cash).transfer(activeStrategy, invested), "invest");
        totalShares = amount;
        accountedAssets = amount;
        balanceOf[receiver] = amount;
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        require(amount != 0 && receiver != address(0), "deposit");
        shares = amount * totalShares / accountedAssets;
        require(shares != 0, "shares");
        require(IERC20Like(cash).transferFrom(msg.sender, address(this), amount), "transfer");
        totalShares += shares;
        accountedAssets += amount;
        balanceOf[receiver] += shares;
        emit Deposit(msg.sender, receiver, amount, shares);
    }

    function rebalance() external {
        address next = KestrelAllocationAdvisor(advisor).recommendedStrategy();
        require(next != activeStrategy, "unchanged");
        address previous = activeStrategy;
        uint256 released = KestrelStrategy(previous).releaseCash();
        activeStrategy = next;
        lastMigrationBlock = block.number;
        accountedAssets = KestrelAccountingRouter(accountingRouter).estimate(address(this), next);
        emit StrategyMigrated(previous, next, released, accountedAssets);
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares != 0 && receiver != address(0), "redeem");
        assets = shares * accountedAssets / totalShares;
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        accountedAssets -= assets;
        require(IERC20Like(cash).transfer(receiver, assets), "transfer");
    }
}
