// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./SableClearing.sol";
import "./SableMath.sol";

interface ISablePath {
    function execute(address owner, bytes calldata command) external returns (bytes memory result);
}

contract SableSettlementVault {
    address public administrator = msg.sender;
    address public engine;
    mapping(address => mapping(address => uint256)) public surplus;

    event SurplusChanged(address indexed owner, address indexed token, int256 delta);

    function bind(address engine_) external {
        require(msg.sender == administrator && engine == address(0), "configuration");
        engine = engine_;
        administrator = address(0);
    }

    function depositFor(address owner, address token, uint256 amount) external {
        require(msg.sender == engine && amount != 0, "engine");
        require(IERC20Like(token).transferFrom(owner, address(this), amount), "transfer");
        surplus[owner][token] += amount;
        emit SurplusChanged(owner, token, int256(amount));
    }

    function settle(address owner, address token, int128 flow) external {
        require(msg.sender == engine, "engine");
        if (flow > 0) {
            surplus[owner][token] -= uint128(flow);
            emit SurplusChanged(owner, token, -int256(uint256(uint128(flow))));
        } else if (flow < 0) {
            uint256 credit = uint256(uint128(-flow));
            surplus[owner][token] += credit;
            emit SurplusChanged(owner, token, int256(credit));
        }
    }

    function withdrawFor(address owner, address token, uint256 amount, address receiver) external {
        require(msg.sender == engine && receiver != address(0), "engine");
        surplus[owner][token] -= amount;
        require(IERC20Like(token).transfer(receiver, amount), "transfer");
        emit SurplusChanged(owner, token, -int256(amount));
    }
}

contract SableCurveEngine {
    struct PoolState {
        int24 tick;
        int24 settlementTick;
        uint16 gridSize;
        uint16 feeBps;
        uint128 sqrtPriceX64;
        uint128 basePerTick;
        uint128 curveLiquidity;
        uint128 seedDeflatorX64;
        uint128 maximumLiquidity;
        uint128 settlementLimit;
        bool initialized;
    }

    struct RangePosition {
        uint128 liquidity;
        uint128 posted;
        uint128 deflatorCheckpointX64;
        int24 lower;
        int24 upper;
        uint8 reserveFlags;
        bool entered;
        bool exited;
        bool active;
    }

    address public administrator = msg.sender;
    address public router;
    address public settlementAsset;
    address public baseAsset;
    address public vault;
    address public hotPath;
    address public warmPath;
    address public coldPath;
    address public clearingPolicy;
    uint32 public initializedPoolCount;
    mapping(uint256 => PoolState) public pools;
    mapping(bytes32 => RangePosition) private ranges;
    mapping(address => mapping(uint256 => bytes32)) private activeRange;

    event PoolMoved(uint256 indexed pool, int24 fromTick, int24 toTick, address indexed trader, uint256 ticks);

    function configure(
        address router_,
        address cash,
        address base,
        address vault_,
        address hot,
        address warm,
        address cold,
        address clearing
    ) external {
        require(msg.sender == administrator && router == address(0));
        router = router_;
        settlementAsset = cash;
        baseAsset = base;
        vault = vault_;
        hotPath = hot;
        warmPath = warm;
        coldPath = cold;
        clearingPolicy = clearing;
    }

    function initializePool(
        uint256 pool,
        int24 tick,
        int24 settlementTick,
        uint16 gridSize,
        uint16 feeBps,
        uint128 basePerTick,
        uint128 curveLiquidity,
        uint128 maximumLiquidity,
        uint128 settlementLimit
    ) external {
        require(msg.sender == administrator && !pools[pool].initialized, "administrator");
        require(gridSize >= 40 && gridSize <= 1_600 && feeBps <= 100, "pool bounds");
        require(
            settlementTick > tick && (settlementTick - tick) % int24(uint24(gridSize)) == 0 && basePerTick != 0
                && curveLiquidity != 0 && maximumLiquidity != 0 && settlementLimit != 0,
            "pool state"
        );
        pools[pool] = PoolState(
            tick,
            settlementTick,
            gridSize,
            feeBps,
            SableTickMath.ratioAtTick(tick),
            basePerTick,
            curveLiquidity,
            uint128(SableRangeMath.Q64),
            maximumLiquidity,
            settlementLimit,
            true
        );
        ++initializedPoolCount;
    }

    function finishConfiguration() external {
        require(
            msg.sender == administrator && initializedPoolCount >= 64
                && SableClearingPolicy(clearingPolicy).engine() == address(this)
        );
        administrator = address(0);
    }

    function depositSurplus(address owner, address token, uint256 amount) external {
        require(msg.sender == coldPath && (token == settlementAsset || token == baseAsset), "cold path");
        SableSettlementVault(vault).depositFor(owner, token, amount);
    }

    function withdrawSurplus(address owner, address token, uint256 amount, address receiver)
        external
        returns (uint256 withdrawn)
    {
        require(msg.sender == coldPath && (token == settlementAsset || token == baseAsset), "cold path");
        if (token == settlementAsset) {
            require(SableClearingPolicy(clearingPolicy).cleared(owner), "clearing");
        }
        uint256 available = SableSettlementVault(vault).surplus(owner, token);
        withdrawn = amount == 0 ? available : amount;
        SableSettlementVault(vault).withdrawFor(owner, token, withdrawn, receiver == address(0) ? owner : receiver);
    }

    function swap(
        address owner,
        address base,
        address quote,
        uint256 poolId,
        bool buy,
        bool inBaseQuantity,
        uint128 quantity,
        uint128 limitPrice,
        uint128 minimumOut,
        uint8 reserveFlags
    ) external returns (SableRangeMath.Flows memory flow, int24 afterTick) {
        require(msg.sender == hotPath && base == baseAsset && quote == settlementAsset, "hot path");
        PoolState storage pool = pools[poolId];
        require(pool.initialized && inBaseQuantity && quantity != 0 && reserveFlags & 1 == 1, "swap");

        int24 beforeTick = pool.tick;
        int24 limitTick = _tickAtOrInside(limitPrice, beforeTick, buy);
        uint256 requestedTicks = uint256(quantity) / pool.basePerTick;
        uint256 limitTicks = uint256(uint24(buy ? limitTick - beforeTick : beforeTick - limitTick));
        uint256 movementCap = pool.gridSize;
        uint256 moved = requestedTicks < limitTicks ? requestedTicks : limitTicks;
        if (moved > movementCap) moved = movementCap;
        require(moved != 0, "movement");
        afterTick = buy ? beforeTick + int24(int256(moved)) : beforeTick - int24(int256(moved));
        // Every initialized venue is intentionally confined to its quoted
        // execution band. This prevents ordinary cross-venue arbitrage from
        // being confused with range-accounting proceeds.
        require(
            afterTick >= pool.settlementTick - int24(uint24(pool.gridSize * 17))
                && afterTick <= pool.settlementTick + 80,
            "band"
        );

        uint256 grossBase = moved * pool.basePerTick;
        int24 midpoint = beforeTick + (afterTick - beforeTick) / 2;
        uint256 grossQuote = grossBase * SableRangeMath.priceWad(SableTickMath.ratioAtTick(midpoint)) / 1 ether;
        require(grossBase <= uint128(type(int128).max) && grossQuote <= uint128(type(int128).max), "flow");
        if (buy) {
            uint256 quoteOut = grossQuote * (10_000 - pool.feeBps) / 10_000;
            require(quoteOut >= minimumOut, "minimum");
            flow.base = int128(int256(grossBase));
            flow.quote = -int128(int256(quoteOut));
        } else {
            uint256 baseOut = grossBase * (10_000 - pool.feeBps) / 10_000;
            require(baseOut >= minimumOut, "minimum");
            flow.base = -int128(int256(baseOut));
            flow.quote = int128(int256(grossQuote));
        }
        SableSettlementVault(vault).settle(owner, baseAsset, flow.base);
        SableSettlementVault(vault).settle(owner, settlementAsset, flow.quote);

        pool.tick = afterTick;
        pool.sqrtPriceX64 = SableTickMath.ratioAtTick(afterTick);
        _markCrossing(owner, poolId, beforeTick, afterTick);
        emit PoolMoved(poolId, beforeTick, afterTick, owner, moved);
    }

    function changeRange(
        address owner,
        uint8 code,
        address base,
        address quote,
        uint256 poolId,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint128 minimumPrice,
        uint128 maximumPrice,
        uint8 reserveFlags
    ) external returns (SableRangeMath.Flows memory flow) {
        require(msg.sender == warmPath && base == baseAsset && quote == settlementAsset, "warm path");
        PoolState storage pool = pools[poolId];
        require(pool.initialized && lower < upper && reserveFlags & 1 == 1, "range");
        require(minimumPrice <= pool.sqrtPriceX64 && pool.sqrtPriceX64 < maximumPrice, "price bounds");
        bytes32 key = _rangeKey(owner, poolId, lower, upper, reserveFlags);
        RangePosition storage position = ranges[key];
        if (code == 1) {
            require(activeRange[owner][poolId] == bytes32(0) && liquidity != 0, "position");
            require(pool.tick == pool.settlementTick, "band");
            require(lower > pool.tick && lower - pool.tick <= int24(uint24(pool.gridSize)), "range placement");
            uint256 width = uint256(uint24(upper - lower));
            require(width >= 8 && width <= 64 && liquidity <= pool.maximumLiquidity, "range size");
            uint128 posted = SableRangeMath.postedBase(liquidity, lower, upper);
            require(posted <= uint128(type(int128).max), "posted");
            flow.base = int128(posted);
            SableSettlementVault(vault).settle(owner, baseAsset, flow.base);
            ranges[key] =
                RangePosition(liquidity, posted, pool.seedDeflatorX64, lower, upper, reserveFlags, false, false, true);
            activeRange[owner][poolId] = key;
            return flow;
        }

        require(
            code == 5 && position.active && position.entered && !position.exited && pool.tick > position.lower
                && pool.tick < position.upper,
            "position"
        );
        SableClearingPolicy(clearingPolicy).record(owner, poolId);
        flow = SableRangeMath.settle(
            position.liquidity,
            position.posted,
            position.deflatorCheckpointX64,
            pool.seedDeflatorX64,
            pool.curveLiquidity,
            position.lower,
            position.upper,
            pool.tick,
            position.reserveFlags
        );
        if (flow.quote < -int128(pool.settlementLimit)) {
            flow.quote = -int128(pool.settlementLimit);
        }
        SableSettlementVault(vault).settle(owner, baseAsset, flow.base);
        SableSettlementVault(vault).settle(owner, settlementAsset, flow.quote);
        delete activeRange[owner][poolId];
        delete ranges[key];
    }

    function _rangeKey(address owner, uint256 pool, int24 lower, int24 upper, uint8 reserveFlags)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, pool, lower, upper, reserveFlags));
    }

    function _markCrossing(address owner, uint256 poolId, int24 beforeTick, int24 afterTick) private {
        bytes32 key = activeRange[owner][poolId];
        if (key == bytes32(0)) return;
        RangePosition storage position = ranges[key];
        if (!position.entered && beforeTick < position.lower && afterTick >= position.lower) {
            PoolState storage pool = pools[poolId];
            pool.seedDeflatorX64 =
                SableRangeMath.rollDeflator(pool.seedDeflatorX64, pool.curveLiquidity, position.liquidity, true);
            position.entered = true;
        }
        if (!position.exited && beforeTick < position.upper && afterTick >= position.upper) {
            PoolState storage pool = pools[poolId];
            pool.seedDeflatorX64 =
                SableRangeMath.rollDeflator(pool.seedDeflatorX64, pool.curveLiquidity, position.liquidity, false);
            position.exited = true;
        }
    }

    function _tickAtOrInside(uint128 ratio, int24 current, bool buy) private pure returns (int24 tick) {
        int24 low = buy ? current + 1 : SableTickMath.MIN_TICK;
        int24 high = buy ? SableTickMath.MAX_TICK : current - 1;
        for (uint256 i; i < 21; ++i) {
            int24 middle = low + (high - low) / 2;
            uint128 middleRatio = SableTickMath.ratioAtTick(middle);
            if (middleRatio < ratio) low = middle + 1;
            else high = middle;
        }
        tick = buy ? low : high;
        if (!buy && SableTickMath.ratioAtTick(tick) > ratio) --tick;
    }
}

contract SableCommandRouter {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public baseAsset;
    address public protectedReserve;
    address public liquidityProvider;
    address public conversionVenue;
    address public query;
    mapping(uint16 => address) public pathModule;

    event PathInstalled(uint16 indexed path, address indexed module);

    function configure(address cash, address base, address vault, address lender, address conversion, address query_)
        external
    {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        baseAsset = base;
        protectedReserve = vault;
        liquidityProvider = lender;
        conversionVenue = conversion;
        query = query_;
    }

    function install(uint16 path, address module) external {
        require(msg.sender == administrator && path > 0 && path <= 3 && module != address(0), "administrator");
        pathModule[path] = module;
        emit PathInstalled(path, module);
    }

    function finishConfiguration() external {
        require(
            msg.sender == administrator && pathModule[1] != address(0) && pathModule[2] != address(0)
                && pathModule[3] != address(0),
            "paths"
        );
        administrator = address(0);
    }

    function userCmd(uint16 path, bytes calldata command) external returns (bytes memory result) {
        address module = pathModule[path];
        require(module != address(0), "path");
        return ISablePath(module).execute(msg.sender, command);
    }
}
