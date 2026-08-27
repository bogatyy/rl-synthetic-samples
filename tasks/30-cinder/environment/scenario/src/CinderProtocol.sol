// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./CinderRisk.sol";
import "./LocalPrimitives.sol";

contract ReserveWrapper {
    string public name;
    string public symbol;
    address public immutable asset;
    address public administrator = msg.sender;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(address asset_, string memory symbol_) {
        asset = asset_;
        name = string.concat("Reserve ", symbol_);
        symbol = symbol_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address receiver, uint256 shares) external returns (bool) {
        _move(msg.sender, receiver, shares);
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 shares) external returns (bool) {
        uint256 permitted = allowance[owner][msg.sender];
        if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - shares;
        _move(owner, receiver, shares);
        return true;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20Like(asset).balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * totalAssets() / totalSupply;
    }

    function previewMint(uint256 shares) public view returns (uint256 assets) {
        uint256 numerator = shares * totalAssets();
        assets = numerator == 0 ? shares : (numerator - 1) / totalSupply + 1;
    }

    function bootstrap(uint256 assets, uint256 shares, address receiver) external {
        require(msg.sender == administrator && totalSupply == 0, "bootstrap");
        require(assets != 0 && shares != 0 && receiver != address(0), "values");
        require(IERC20Like(asset).transferFrom(msg.sender, address(this), assets), "transfer");
        totalSupply = shares;
        balanceOf[receiver] = shares;
        emit Transfer(address(0), receiver, shares);
        administrator = address(0);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewMint(shares);
        require(IERC20Like(asset).transferFrom(msg.sender, address(this), assets), "transfer");
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Transfer(address(0), receiver, shares);
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares != 0 && shares <= balanceOf[msg.sender], "shares");
        assets = convertToAssets(shares);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        emit Transfer(msg.sender, address(0), shares);
        require(IERC20Like(asset).transfer(receiver, assets), "transfer");
    }

    function _move(address owner, address receiver, uint256 shares) private {
        require(receiver != address(0), "receiver");
        balanceOf[owner] -= shares;
        balanceOf[receiver] += shares;
        emit Transfer(owner, receiver, shares);
    }
}

contract CinderConversionPool {
    address public immutable cash;
    address public immutable underlying;
    uint112 public cashReserve;
    uint112 public underlyingReserve;

    constructor(address cash_, address underlying_) {
        cash = cash_;
        underlying = underlying_;
    }

    function seed(uint256 cashAmount, uint256 underlyingAmount) external {
        require(cashReserve == 0 && underlyingReserve == 0, "seeded");
        require(IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount), "cash");
        require(IERC20Like(underlying).transferFrom(msg.sender, address(this), underlyingAmount), "underlying");
        _sync();
    }

    function cashForExactUnderlying(uint256 underlyingOut) public view returns (uint256 cashIn) {
        require(underlyingOut != 0 && underlyingOut < underlyingReserve, "output");
        uint256 numerator = uint256(cashReserve) * underlyingOut * 10_000;
        uint256 denominator = (uint256(underlyingReserve) - underlyingOut) * 9_970;
        cashIn = numerator / denominator + 1;
    }

    function buyExactUnderlying(uint256 underlyingOut, uint256 maximumCash, address receiver)
        external
        returns (uint256 cashIn)
    {
        cashIn = cashForExactUnderlying(underlyingOut);
        require(cashIn <= maximumCash && receiver != address(0), "slippage");
        require(IERC20Like(cash).transferFrom(msg.sender, address(this), cashIn), "cash");
        require(IERC20Like(underlying).transfer(receiver, underlyingOut), "underlying");
        _sync();
    }

    function _sync() private {
        uint256 cashBalance = IERC20Like(cash).balanceOf(address(this));
        uint256 underlyingBalance = IERC20Like(underlying).balanceOf(address(this));
        require(cashBalance <= type(uint112).max && underlyingBalance <= type(uint112).max, "reserves");
        cashReserve = uint112(cashBalance);
        underlyingReserve = uint112(underlyingBalance);
    }
}

contract IndexedLendingPool {
    struct Account {
        uint128 cashCollateral;
        uint128 cashDebt;
        address wrapperCollateral;
        uint128 wrapperShares;
        address wrapperDebtAsset;
        uint128 wrapperDebtShares;
    }

    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public creditPolicy;
    uint128 public cashBorrowLimit;
    uint32 public listedMarketCount;
    mapping(address => bool) public listedMarket;
    mapping(address => uint256) public wrapperInventory;
    mapping(address => uint256) public marketBorrowers;
    mapping(address => uint256) public marketCashBorrowed;
    mapping(address => mapping(address => bool)) public knownMarketAccount;
    mapping(address => Account) public accounts;

    event Supplied(address indexed account, address indexed asset, uint256 amount);
    event Borrowed(address indexed account, address indexed asset, address indexed receiver, uint256 amount);
    event Repaid(address indexed payer, address indexed account, address indexed asset, uint256 amount);

    function configure(address cash, address policy) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = address(this);
        creditPolicy = policy;
        cashBorrowLimit = 30_000_000 ether;
    }

    function listMarket(address wrapper) external {
        require(msg.sender == administrator && !listedMarket[wrapper], "administrator");
        require(CreditPolicy(creditPolicy).isListed(wrapper), "policy");
        listedMarket[wrapper] = true;
        wrapperInventory[wrapper] = IERC20Like(wrapper).balanceOf(address(this));
        ++listedMarketCount;
    }

    function finishConfiguration() external {
        require(msg.sender == administrator && listedMarketCount >= 4, "configuration");
        administrator = address(0);
    }

    function supplyCash(uint256 amount, address account) external {
        require(amount != 0, "amount");
        require(IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), amount), "transfer");
        accounts[account].cashCollateral += uint128(amount);
        emit Supplied(account, settlementAsset, amount);
    }

    function withdrawCash(uint256 amount, address receiver) external {
        Account storage account = accounts[msg.sender];
        account.cashCollateral -= uint128(amount);
        require(_debtValue(account) <= _capacity(account), "health");
        require(IERC20Like(settlementAsset).transfer(receiver, amount), "transfer");
    }

    function supplyWrapper(address wrapper, uint256 shares, address account) external {
        require(listedMarket[wrapper] && shares != 0, "market");
        Account storage state = accounts[account];
        require(state.wrapperCollateral == address(0) || state.wrapperCollateral == wrapper, "collateral");
        require(state.wrapperDebtShares == 0, "isolation");
        if (!knownMarketAccount[wrapper][account]) {
            (uint256 accountCap,) = CreditPolicy(creditPolicy).marketLimits(wrapper);
            require(marketBorrowers[wrapper] < accountCap, "market account cap");
            knownMarketAccount[wrapper][account] = true;
            ++marketBorrowers[wrapper];
        }
        require(IERC20Like(wrapper).transferFrom(msg.sender, address(this), shares), "transfer");
        wrapperInventory[wrapper] += shares;
        state.wrapperCollateral = wrapper;
        state.wrapperShares += uint128(shares);
        emit Supplied(account, wrapper, shares);
    }

    function borrowWrapper(address wrapper, uint256 shares, address receiver) external {
        require(
            listedMarket[wrapper] && CreditPolicy(creditPolicy).wrapperDebtEnabled(wrapper) && shares != 0, "market"
        );
        wrapperInventory[wrapper] -= shares;
        Account storage account = accounts[msg.sender];
        require(account.wrapperShares == 0, "isolation");
        require(account.wrapperDebtAsset == address(0) || account.wrapperDebtAsset == wrapper, "debt asset");
        account.wrapperDebtAsset = wrapper;
        account.wrapperDebtShares += uint128(shares);
        require(_debtValue(account) <= _capacity(account), "health");
        require(IERC20Like(wrapper).transfer(receiver, shares), "transfer");
        emit Borrowed(msg.sender, wrapper, receiver, shares);
    }

    function repayWrapper(address wrapper, uint256 shares, address account) external {
        Account storage state = accounts[account];
        require(state.wrapperDebtAsset == wrapper && shares <= state.wrapperDebtShares, "debt");
        require(IERC20Like(wrapper).transferFrom(msg.sender, address(this), shares), "transfer");
        state.wrapperDebtShares -= uint128(shares);
        wrapperInventory[wrapper] += shares;
        emit Repaid(msg.sender, account, wrapper, shares);
    }

    function borrowCash(uint256 amount, address receiver) external {
        require(amount != 0, "amount");
        Account storage account = accounts[msg.sender];
        account.cashDebt += uint128(amount);
        require(account.cashDebt <= cashBorrowLimit, "account limit");
        if (account.wrapperCollateral != address(0)) {
            (, uint256 exposureCap) = CreditPolicy(creditPolicy).marketLimits(account.wrapperCollateral);
            uint256 nextExposure = marketCashBorrowed[account.wrapperCollateral] + amount;
            require(nextExposure <= exposureCap, "market exposure");
            marketCashBorrowed[account.wrapperCollateral] = nextExposure;
        }
        require(_debtValue(account) <= _capacity(account), "health");
        require(IERC20Like(settlementAsset).transfer(receiver, amount), "transfer");
        emit Borrowed(msg.sender, settlementAsset, receiver, amount);
    }

    function availableCash(address accountAddress) external view returns (uint256) {
        Account memory account = accounts[accountAddress];
        uint256 capacity = _capacity(account);
        uint256 debt = _debtValue(account);
        if (debt >= capacity) return 0;
        uint256 available = capacity - debt;
        uint256 accountRemaining = cashBorrowLimit - account.cashDebt;
        if (available > accountRemaining) available = accountRemaining;
        uint256 liquid = IERC20Like(settlementAsset).balanceOf(address(this));
        return available < liquid ? available : liquid;
    }

    function accountValues(address accountAddress) external view returns (uint256 capacity, uint256 debt) {
        Account memory account = accounts[accountAddress];
        return (_capacity(account), _debtValue(account));
    }

    function _capacity(Account memory account) private view returns (uint256) {
        uint256 capacity = uint256(account.cashCollateral) * 9_900 / 10_000;
        if (account.wrapperCollateral != address(0)) {
            capacity += CreditPolicy(creditPolicy).collateralCapacity(account.wrapperCollateral, account.wrapperShares);
        }
        return capacity;
    }

    function _debtValue(Account memory account) private view returns (uint256) {
        uint256 value = account.cashDebt;
        if (account.wrapperDebtAsset != address(0)) {
            value += CreditPolicy(creditPolicy).wrapperDebtValue(account.wrapperDebtAsset, account.wrapperDebtShares);
        }
        return value;
    }
}
