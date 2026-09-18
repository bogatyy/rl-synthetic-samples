// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {TickMath} from "./ambient/libraries/TickMath.sol";

interface IFixtureCrocSlots {
    function readSlot(uint256 slot) external view returns (uint256);
    function acceptCrocDex() external pure returns (bool);
}

contract FixtureCrocQuery {
    uint256 private constant CURVE_MAP_SLOT = 65551;
    uint256 private constant BALANCE_MAP_SLOT = 65552;
    address public immutable dex;

    constructor(address dex_) {
        require(dex_ != address(0) && IFixtureCrocSlots(dex_).acceptCrocDex(), "dex");
        dex = dex_;
    }

    function queryCurve(address base, address quote, uint256 poolIndex)
        public
        view
        returns (uint128 priceRoot, uint128 ambientSeeds, uint128 concentratedLiquidity, uint64 seedDeflator, uint64 growth)
    {
        bytes32 pool = keccak256(abi.encode(base, quote, poolIndex));
        bytes32 slot = keccak256(abi.encode(pool, CURVE_MAP_SLOT));
        uint256 first = IFixtureCrocSlots(dex).readSlot(uint256(slot));
        uint256 second = IFixtureCrocSlots(dex).readSlot(uint256(slot) + 1);
        priceRoot = uint128(first);
        ambientSeeds = uint128(first >> 128);
        concentratedLiquidity = uint128(second);
        seedDeflator = uint64(second >> 128);
        growth = uint64(second >> 192);
    }

    function queryCurveTick(address base, address quote, uint256 poolIndex) external view returns (int24) {
        (uint128 price,,,,) = queryCurve(base, quote, poolIndex);
        return TickMath.getTickAtSqrtRatio(price);
    }

    function queryLiquidity(address base, address quote, uint256 poolIndex) external view returns (uint128) {
        (, uint128 ambient, uint128 concentrated, uint64 deflator,) = queryCurve(base, quote, poolIndex);
        return uint128((uint256(ambient) * uint256(deflator)) >> 48) + concentrated;
    }

    function querySurplus(address owner, address token) external view returns (uint128) {
        bytes32 key = keccak256(abi.encode(owner, token));
        bytes32 slot = keccak256(abi.encode(key, BALANCE_MAP_SLOT));
        return uint128(IFixtureCrocSlots(dex).readSlot(uint256(slot)));
    }
}

