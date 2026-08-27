// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SableMath.sol";

interface ISableCurveView {
    function pools(uint256 pool)
        external
        view
        returns (
            int24 tick,
            int24 settlementTick,
            uint16 gridSize,
            uint16 feeBps,
            uint128 sqrtPriceX64,
            uint128 basePerTick,
            uint128 curveLiquidity,
            uint128 seedDeflatorX64,
            uint128 maximumLiquidity,
            uint128 settlementLimit,
            bool initialized
        );
}

contract SableCurveQuery {
    address public immutable engine;

    event QueryConfigured(address indexed engine);

    constructor(address engine_) {
        engine = engine_;
        emit QueryConfigured(engine_);
    }

    function currentTick(uint256 pool) external view returns (int24 tick) {
        (tick,,,,,,,,,,) = ISableCurveView(engine).pools(pool);
    }

    function ratioAtTick(int24 tick) external pure returns (uint128) {
        return SableTickMath.ratioAtTick(tick);
    }
}
