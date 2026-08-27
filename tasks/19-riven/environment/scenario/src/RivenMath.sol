// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RivenFixedPoint {
    uint256 internal constant ONE = 1 ether;

    function mulDown(uint256 left, uint256 right) internal pure returns (uint256) {
        return left * right / ONE;
    }

    function mulUp(uint256 left, uint256 right) internal pure returns (uint256) {
        uint256 product = left * right;
        return product == 0 ? 0 : (product - 1) / ONE + 1;
    }

    function divUp(uint256 left, uint256 right) internal pure returns (uint256) {
        uint256 numerator = left * ONE;
        return numerator == 0 ? 0 : (numerator - 1) / right + 1;
    }

    function divDown(uint256 left, uint256 right) internal pure returns (uint256) {
        return left * ONE / right;
    }
}

library RivenStableMath {
    uint256 internal constant AMP_PRECISION = 1_000;

    function invariant(uint256 amplification, uint256[2] memory balances) internal pure returns (uint256 value) {
        uint256 sum = balances[0] + balances[1];
        if (sum == 0) return 0;
        value = sum;
        uint256 ampTimesTotal = amplification * 2;
        for (uint256 iteration; iteration < 255; ++iteration) {
            uint256 productTerm = value;
            productTerm = productTerm * value / (balances[0] * 2);
            productTerm = productTerm * value / (balances[1] * 2);
            uint256 previous = value;
            value = ((ampTimesTotal * sum / AMP_PRECISION + productTerm * 2) * value)
                / ((ampTimesTotal - AMP_PRECISION) * value / AMP_PRECISION + productTerm * 3);
            if (value > previous ? value - previous <= 1 : previous - value <= 1) return value;
        }
        revert("invariant convergence");
    }

    function inputForExactOutput(
        uint256 amplification,
        uint256[2] memory balances,
        uint8 indexIn,
        uint8 indexOut,
        uint256 amountOut,
        uint256 invariantBefore
    ) internal pure returns (uint256 amountIn) {
        require(indexIn < 2 && indexOut < 2 && indexIn != indexOut && amountOut < balances[indexOut], "indices");
        balances[indexOut] -= amountOut;
        uint256 finalIn = balanceAtInvariant(amplification, balances, invariantBefore, indexIn);
        amountIn = finalIn - balances[indexIn] + 1;
    }

    function balanceAtInvariant(
        uint256 amplification,
        uint256[2] memory balances,
        uint256 invariantValue,
        uint8 unknown
    ) internal pure returns (uint256 value) {
        uint256 ampTimesTotal = amplification * 2;
        uint256 known = balances[unknown == 0 ? 1 : 0];
        uint256 c = invariantValue * invariantValue / (known * 2);
        c = c * invariantValue * AMP_PRECISION / (ampTimesTotal * 2);
        uint256 b = known + invariantValue * AMP_PRECISION / ampTimesTotal;
        value = invariantValue;
        for (uint256 iteration; iteration < 255; ++iteration) {
            uint256 previous = value;
            value = (value * value + c) / (2 * value + b - invariantValue);
            if (value > previous ? value - previous <= 1 : previous - value <= 1) return value;
        }
        revert("balance convergence");
    }
}
