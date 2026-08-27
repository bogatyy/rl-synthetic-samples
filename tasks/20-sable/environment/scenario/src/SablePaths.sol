// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SableProtocol.sol";

contract SableHotPath is ISablePath {
    address public immutable router;
    address public immutable engine;

    constructor(address router_, address engine_) {
        router = router_;
        engine = engine_;
    }

    function execute(address owner, bytes calldata command) external returns (bytes memory result) {
        require(msg.sender == router, "router");
        (
            address base,
            address quote,
            uint256 pool,
            bool buy,
            bool inBaseQuantity,
            uint128 quantity,
            uint16 tip,
            uint128 limitPrice,
            uint128 minimumOut,
            uint8 reserveFlags
        ) = abi.decode(command, (address, address, uint256, bool, bool, uint128, uint16, uint128, uint128, uint8));
        require(tip <= 100, "tip");
        (SableRangeMath.Flows memory flow, int24 tick) = SableCurveEngine(engine)
            .swap(owner, base, quote, pool, buy, inBaseQuantity, quantity, limitPrice, minimumOut, reserveFlags);
        return abi.encode(flow.base, flow.quote, tick);
    }
}

contract SableWarmPath is ISablePath {
    struct RangeCommand {
        uint8 code;
        address base;
        address quote;
        uint256 pool;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint128 minimumPrice;
        uint128 maximumPrice;
        uint8 reserveFlags;
        address conduit;
    }

    address public immutable router;
    address public immutable engine;

    constructor(address router_, address engine_) {
        router = router_;
        engine = engine_;
    }

    function execute(address owner, bytes calldata command) external returns (bytes memory result) {
        require(msg.sender == router, "router");
        RangeCommand memory request = abi.decode(command, (RangeCommand));
        require(request.conduit == address(0), "conduit");
        SableRangeMath.Flows memory flow = SableCurveEngine(engine)
            .changeRange(
                owner,
                request.code,
                request.base,
                request.quote,
                request.pool,
                request.lower,
                request.upper,
                request.liquidity,
                request.minimumPrice,
                request.maximumPrice,
                request.reserveFlags
            );
        return abi.encode(flow.base, flow.quote);
    }
}

contract SableColdPath is ISablePath {
    address public immutable router;
    address public immutable engine;

    constructor(address router_, address engine_) {
        router = router_;
        engine = engine_;
    }

    function execute(address owner, bytes calldata command) external returns (bytes memory result) {
        require(msg.sender == router, "router");
        (uint8 code, address token, uint128 amount, address receiver) =
            abi.decode(command, (uint8, address, uint128, address));
        if (code == 73) {
            SableCurveEngine(engine).depositSurplus(owner, token, amount);
            return abi.encode(uint256(amount));
        }
        require(code == 74, "code");
        uint256 withdrawn = SableCurveEngine(engine).withdrawSurplus(owner, token, amount, receiver);
        return abi.encode(withdrawn);
    }
}
