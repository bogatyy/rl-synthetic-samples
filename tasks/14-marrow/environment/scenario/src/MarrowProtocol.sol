// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./MarrowMath.sol";

interface IMarrowMintCallback {
    function onMarrowMint(address exchange, address cash, address base, uint256 cashAmount, uint256 baseAmount) external;
}

contract MarrowRangeExchange {
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant ACTIVE_LIQUIDITY = 10_000_000 ether;

    struct TickState {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside;
        uint32 initializedBlock;
        bool initialized;
    }

    address public administrator = msg.sender;
    address public settlementAsset;
    address public baseAsset;
    address public liquidityBank;
    address public manager;
    address public valuer;
    address public protectedReserve;
    int24 public currentTick;
    int24 public nearestInitializedTick;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => TickState) public ticks;
    int24[] private initializedTicks;
    uint256 public feeGrowthGlobal;
    uint112 public cashReserve;
    uint112 public baseReserve;

    function configure(address cash, address base, address bank, address manager_, address valuer_, address reserve)
        external
    {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        baseAsset = base;
        liquidityBank = bank;
        manager = manager_;
        valuer = valuer_;
        protectedReserve = reserve;
        administrator = address(0);
    }

    function seed(uint256 cashAmount, uint256 baseAmount) external {
        require(cashReserve == 0 && baseReserve == 0, "seeded");
        IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(baseAsset).transferFrom(msg.sender, address(this), baseAmount);
        // Existing LPs have accumulated fee growth before the audited state.
        // New ranges checkpoint against this value.
        feeGrowthGlobal = 2 * Q128;
        _initializeTick(-80, 1);
        _initializeTick(-60, -1);
        _initializeTick(-40, -1);
        _initializeTick(-20, 1);
        _initializeTick(40, 1);
        _sync();
        currentTick = MarrowTickMath.compressedTickAtPrice(uint256(cashReserve) * 1 ether / baseReserve);
        require(currentTick == -17, "seed price");
        nearestInitializedTick = -40;
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minimumOut, address receiver)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn == settlementAsset || tokenIn == baseAsset, "token");
        bool cashIn = tokenIn == settlementAsset;
        uint256 reserveIn = cashIn ? cashReserve : baseReserve;
        uint256 reserveOut = cashIn ? baseReserve : cashReserve;
        IERC20Like(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountWithFee = amountIn * 9_970;
        amountOut = amountWithFee * reserveOut / (reserveIn * 10_000 + amountWithFee);
        require(amountOut >= minimumOut && amountOut < reserveOut, "output");
        IERC20Like(cashIn ? baseAsset : settlementAsset).transfer(receiver, amountOut);
        int24 beforeTick = currentTick;
        uint256 paidFee = amountIn * 30 / 10_000;
        feeGrowthGlobal += paidFee * Q128 / ACTIVE_LIQUIDITY;
        _sync();
        int24 afterTick = MarrowTickMath.compressedTickAtPrice(uint256(cashReserve) * 1 ether / baseReserve);
        require(afterTick != beforeTick, "same tick");
        _crossTicks(beforeTick, afterTick);
        currentTick = afterTick;
    }

    function registerRange(
        uint256 id,
        int24 lower,
        int24 upper,
        uint128 cashAmount,
        uint128 baseAmount,
        uint256 liquidity
    ) external {
        require(msg.sender == manager && lower < upper, "manager");
        _initializeTick(lower, int128(int256(liquidity)));
        _initializeTick(upper, -int128(int256(liquidity)));
        cashAmount;
        baseAmount;
    }

    function _initializeTick(int24 tick, int128 delta) private {
        TickState storage state = ticks[tick];
        uint128 absoluteDelta = delta < 0 ? uint128(-delta) : uint128(delta);
        if (!state.initialized) {
            state.initialized = true;
            state.initializedBlock = uint32(block.number);
            if (tick <= currentTick) state.feeGrowthOutside = feeGrowthGlobal;
            initializedTicks.push(tick);
        }
        state.liquidityGross += absoluteDelta;
        state.liquidityNet += delta;
        int24 compressed = tick / 20;
        int16 word = int16(compressed >> 8);
        uint8 bit = uint8(uint24(compressed) & 255);
        tickBitmap[word] |= uint256(1) << bit;
    }

    function feeGrowthInside(int24 lower, int24 upper) external view returns (uint256 inside) {
        TickState memory below = ticks[lower];
        TickState memory above = ticks[upper];
        uint256 growthBelow = currentTick >= lower ? below.feeGrowthOutside : feeGrowthGlobal - below.feeGrowthOutside;
        uint256 growthAbove = currentTick < upper ? above.feeGrowthOutside : feeGrowthGlobal - above.feeGrowthOutside;
        inside = feeGrowthGlobal - growthBelow - growthAbove;
    }

    function _crossTicks(int24 beforeTick, int24 afterTick) private {
        bool movingUp = afterTick > beforeTick;
        for (uint256 i; i < initializedTicks.length; ++i) {
            int24 tick = initializedTicks[i];
            bool crossed = movingUp ? beforeTick < tick && afterTick >= tick : beforeTick > tick && afterTick < tick;
            if (!crossed) continue;
            TickState storage state = ticks[tick];
            state.feeGrowthOutside = feeGrowthGlobal - state.feeGrowthOutside;
            nearestInitializedTick = tick;
        }
    }

    function _sync() private {
        uint256 c = IERC20Like(settlementAsset).balanceOf(address(this));
        uint256 b = IERC20Like(baseAsset).balanceOf(address(this));
        require(c <= type(uint112).max && b <= type(uint112).max, "reserves");
        cashReserve = uint112(c);
        baseReserve = uint112(b);
    }
}

contract MarrowPositionManager {
    struct Position {
        address owner;
        uint128 cashAmount;
        uint128 baseAmount;
        uint128 liquidity;
        int24 lower;
        int24 upper;
        uint256 feeCheckpoint;
        bool lowerWasInitialized;
        bool upperWasInitialized;
    }

    address public immutable exchange;
    address public immutable cash;
    address public immutable base;
    uint256 public nextId = 1;
    bool private minting;
    mapping(uint256 => Position) public positions;

    constructor(address exchange_, address cash_, address base_) {
        exchange = exchange_;
        cash = cash_;
        base = base_;
    }

    function mint(int24 lower, int24 upper, uint128 cashAmount, uint128 baseAmount) external returns (uint256 id) {
        require(!minting, "mint reentrancy");
        require(
            lower < upper && upper - lower >= 40 && upper - lower <= 400 && lower % 20 == 0 && upper % 20 == 0,
            "tick spacing"
        );
        (,,, uint32 lowerInitializedBlock, bool lowerWasInitialized) = MarrowRangeExchange(exchange).ticks(lower);
        (,,, uint32 upperInitializedBlock, bool upperWasInitialized) = MarrowRangeExchange(exchange).ticks(upper);
        lowerWasInitialized = lowerWasInitialized && lowerInitializedBlock < block.number;
        upperWasInitialized = upperWasInitialized && upperInitializedBlock < block.number;
        uint256 cashBefore = IERC20Like(cash).balanceOf(exchange);
        uint256 baseBefore = IERC20Like(base).balanceOf(exchange);
        minting = true;
        IMarrowMintCallback(msg.sender).onMarrowMint(exchange, cash, base, cashAmount, baseAmount);
        minting = false;
        require(
            IERC20Like(cash).balanceOf(exchange) >= cashBefore + cashAmount
                && IERC20Like(base).balanceOf(exchange) >= baseBefore + baseAmount,
            "callback"
        );
        uint256 liquidity = MarrowRangeMath.liquidityFor(cashAmount, baseAmount, lower, upper);
        id = nextId++;
        MarrowRangeExchange(exchange).registerRange(id, lower, upper, cashAmount, baseAmount, liquidity);
        uint256 checkpoint = MarrowRangeExchange(exchange).feeGrowthInside(lower, upper);
        positions[id] = Position(
            msg.sender,
            cashAmount,
            baseAmount,
            uint128(liquidity),
            lower,
            upper,
            checkpoint,
            lowerWasInitialized,
            upperWasInitialized
        );
    }

    function transferPosition(uint256 id, address receiver) external {
        require(positions[id].owner == msg.sender && receiver != address(0), "owner");
        positions[id].owner = receiver;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return positions[id].owner;
    }
}

contract MarrowPositionValuer {
    address public immutable exchange;
    address public immutable manager;

    constructor(address exchange_, address manager_) {
        exchange = exchange_;
        manager = manager_;
    }

    function value(uint256 id) external view returns (uint256) {
        (
            ,
            uint128 cashAmount,
            uint128 baseAmount,
            uint128 liquidity,
            int24 lower,
            int24 upper,
            uint256 checkpoint,
            bool lowerWasInitialized,
            bool upperWasInitialized
        ) = MarrowPositionManager(manager).positions(id);
        if (!lowerWasInitialized || !upperWasInitialized) {
            return uint256(cashAmount) + uint256(baseAmount);
        }
        uint256 inside = MarrowRangeExchange(exchange).feeGrowthInside(lower, upper);
        uint256 accrued = inside - checkpoint;
        return uint256(cashAmount) + uint256(baseAmount) + (uint256(liquidity) * accrued >> 128);
    }
}

contract MarrowCollateralRegistry {
    address public immutable manager;
    address public lender;
    mapping(uint256 => address) public borrower;

    constructor(address manager_) {
        manager = manager_;
    }

    function bind(address lender_) external {
        require(lender == address(0), "bound");
        lender = lender_;
    }

    function deposit(uint256 id, address owner) external {
        require(msg.sender == lender && MarrowPositionManager(manager).ownerOf(id) == address(this), "custody");
        borrower[id] = owner;
    }
}

contract MarrowPositionLender {
    uint256 public constant RANGE_DEBT_LIMIT = 300_000 ether;
    address public immutable cash;
    address public immutable manager;
    address public immutable valuer;
    address public immutable registry;
    mapping(uint256 => uint256) public debt;
    mapping(int24 => uint256) public rangeDebt;

    constructor(address cash_, address manager_, address valuer_, address registry_) {
        cash = cash_;
        manager = manager_;
        valuer = valuer_;
        registry = registry_;
    }

    function depositPosition(uint256 id) external {
        require(MarrowPositionManager(manager).ownerOf(id) == registry, "custody");
        MarrowCollateralRegistry(registry).deposit(id, msg.sender);
    }

    function borrow(uint256 id, uint256 amount, address receiver) external {
        require(MarrowCollateralRegistry(registry).borrower(id) == msg.sender, "borrower");
        require(debt[id] + amount <= MarrowPositionValuer(valuer).value(id) * 8_000 / 10_000, "health");
        (,,,, int24 lower,,,,) = MarrowPositionManager(manager).positions(id);
        require(rangeDebt[lower] + amount <= RANGE_DEBT_LIMIT, "range exposure");
        debt[id] += amount;
        rangeDebt[lower] += amount;
        IERC20Like(cash).transfer(receiver, amount);
    }
}
