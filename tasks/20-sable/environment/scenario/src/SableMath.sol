// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library SableTickMath {
    int24 internal constant MIN_TICK = -665_454;
    int24 internal constant MAX_TICK = 831_818;

    function ratioAtTick(int24 tick) internal pure returns (uint128 ratioX64) {
        unchecked {
            require(tick >= MIN_TICK && tick <= MAX_TICK, "tick");
            uint256 absolute = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            uint256 ratio =
                absolute & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absolute & 0x2 != 0) ratio = ratio * 0xfff97272373d413259a46990580e213a >> 128;
            if (absolute & 0x4 != 0) ratio = ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc >> 128;
            if (absolute & 0x8 != 0) ratio = ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0 >> 128;
            if (absolute & 0x10 != 0) ratio = ratio * 0xffcb9843d60f6159c9db58835c926644 >> 128;
            if (absolute & 0x20 != 0) ratio = ratio * 0xff973b41fa98c081472e6896dfb254c0 >> 128;
            if (absolute & 0x40 != 0) ratio = ratio * 0xff2ea16466c96a3843ec78b326b52861 >> 128;
            if (absolute & 0x80 != 0) ratio = ratio * 0xfe5dee046a99a2a811c461f1969c3053 >> 128;
            if (absolute & 0x100 != 0) ratio = ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4 >> 128;
            if (absolute & 0x200 != 0) ratio = ratio * 0xf987a7253ac413176f2b074cf7815e54 >> 128;
            if (absolute & 0x400 != 0) ratio = ratio * 0xf3392b0822b70005940c7a398e4b70f3 >> 128;
            if (absolute & 0x800 != 0) ratio = ratio * 0xe7159475a2c29b7443b29c7fa6e889d9 >> 128;
            if (absolute & 0x1000 != 0) ratio = ratio * 0xd097f3bdfd2022b8845ad8f792aa5825 >> 128;
            if (absolute & 0x2000 != 0) ratio = ratio * 0xa9f746462d870fdf8a65dc1f90e061e5 >> 128;
            if (absolute & 0x4000 != 0) ratio = ratio * 0x70d869a156d2a1b890bb3df62baf32f7 >> 128;
            if (absolute & 0x8000 != 0) ratio = ratio * 0x31be135f97d08fd981231505542fcfa6 >> 128;
            if (absolute & 0x10000 != 0) ratio = ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9 >> 128;
            if (absolute & 0x20000 != 0) ratio = ratio * 0x5d6af8dedb81196699c329225ee604 >> 128;
            if (absolute & 0x40000 != 0) ratio = ratio * 0x2216e584f5fa1ea926041bedfe98 >> 128;
            if (absolute & 0x80000 != 0) ratio = ratio * 0x48a170391f7dc42444e8fa2 >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            ratioX64 = uint128((ratio >> 64) + (ratio % (1 << 64) == 0 ? 0 : 1));
        }
    }
}

library SableRangeMath {
    uint256 internal constant Q64 = 1 << 64;
    uint256 private constant LIQUIDITY_SCALE = 1e12;
    uint256 private constant SETTLEMENT_SCALE = 2_000_000;

    struct Flows {
        int128 base;
        int128 quote;
    }

    function mulDivUp(uint256 value, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        uint256 product = value * numerator;
        return product == 0 ? 0 : (product - 1) / denominator + 1;
    }

    function priceWad(uint128 ratioX64) internal pure returns (uint256) {
        return uint256(ratioX64) * uint256(ratioX64) * 1 ether >> 128;
    }

    function postedBase(uint128 liquidity, int24 lower, int24 upper) internal pure returns (uint128 amount) {
        uint256 width = uint256(uint24(upper - lower));
        uint256 raw = uint256(liquidity) * width / LIQUIDITY_SCALE;
        require(raw != 0 && raw <= type(uint128).max, "posted base");
        amount = uint128(raw);
    }

    function rollDeflator(uint128 deflatorX64, uint128 curveLiquidity, uint128 rangeLiquidity, bool entering)
        internal
        pure
        returns (uint128 next)
    {
        uint256 raw = entering
            ? mulDivUp(deflatorX64, curveLiquidity, uint256(curveLiquidity) + rangeLiquidity)
            : mulDivUp(deflatorX64, uint256(curveLiquidity) + rangeLiquidity, curveLiquidity);
        require(raw <= type(uint128).max, "deflator");
        next = uint128(raw);
    }

    function settle(
        uint128 liquidity,
        uint128 posted,
        uint128 checkpointDeflatorX64,
        uint128 currentDeflatorX64,
        uint128 curveLiquidity,
        int24 lower,
        int24 upper,
        int24 currentTick,
        uint8 reserveFlags
    ) internal pure returns (Flows memory flow) {
        require(reserveFlags & 1 == 1 && currentTick > lower, "surplus");
        require(currentTick > lower && currentTick < upper, "active range");
        uint256 expectedDeflator =
            uint256(checkpointDeflatorX64) * curveLiquidity / (uint256(curveLiquidity) + liquidity);
        require(currentDeflatorX64 > expectedDeflator, "deflator mileage");
        uint256 roundingMileage = currentDeflatorX64 - expectedDeflator;
        uint256 traversed = uint256(uint24(currentTick - lower));
        uint256 remaining = uint256(uint24(upper - currentTick));
        uint256 quoteClaim = roundingMileage * liquidity * traversed * remaining / SETTLEMENT_SCALE;
        require(posted <= uint128(type(int128).max), "base flow");
        require(quoteClaim != 0 && quoteClaim <= uint128(type(int128).max), "quote flow");
        flow.base = -int128(posted);
        flow.quote = -int128(int256(quoteClaim));
    }
}
