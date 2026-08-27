// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./RivenMath.sol";

contract RivenPoolShare {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public immutable vault;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address vault_, string memory symbol_, uint256 supply) {
        vault = vault_;
        name = string.concat("Riven Composable ", symbol_);
        symbol = symbol_;
        totalSupply = supply;
        balanceOf[vault_] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[receiver] += amount;
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[owner][msg.sender];
        if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - amount;
        balanceOf[owner] -= amount;
        balanceOf[receiver] += amount;
        return true;
    }
}

contract RivenRateCache {
    struct Rate {
        uint128 value;
        uint64 duration;
        uint64 updatedAt;
    }

    address public administrator = msg.sender;
    mapping(address => Rate) public rates;

    event RateUpdated(address indexed asset, uint256 value, uint256 duration);

    function configure(address asset, uint128 value, uint64 duration) external {
        require(msg.sender == administrator && value >= 1 ether && duration != 0, "configuration");
        rates[asset] = Rate(value, duration, uint64(block.timestamp));
        emit RateUpdated(asset, value, duration);
    }

    function finishConfiguration() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function current(address asset) external view returns (uint256 value) {
        Rate memory cached = rates[asset];
        require(cached.value != 0 && block.timestamp <= cached.updatedAt + cached.duration, "stale rate");
        return cached.value;
    }
}

contract RivenComposablePool {
    using RivenFixedPoint for uint256;

    address public immutable vault;
    address public immutable rateCache;
    address public immutable shareToken;
    address[3] private assets;
    uint256[3] private decimalScales;
    uint256 public immutable amplification;
    uint256 public immutable feePercentage;
    uint8 public constant shareIndex = 1;

    constructor(
        address vault_,
        address rateCache_,
        address share_,
        address[3] memory assets_,
        uint256[3] memory decimalScales_,
        uint256 amplification_,
        uint256 feePercentage_
    ) {
        require(assets_[1] == share_ && amplification_ >= 10_000 && feePercentage_ <= 1e16, "parameters");
        vault = vault_;
        rateCache = rateCache_;
        shareToken = share_;
        assets = assets_;
        decimalScales = decimalScales_;
        amplification = amplification_;
        feePercentage = feePercentage_;
    }

    function assetAt(uint256 index) external view returns (address) {
        return assets[index];
    }

    function scalingFactors() public view returns (uint256[3] memory factors) {
        factors[0] = decimalScales[0].mulDown(RivenRateCache(rateCache).current(assets[0]));
        factors[1] = 1 ether;
        factors[2] = decimalScales[2].mulDown(RivenRateCache(rateCache).current(assets[2]));
    }

    function actualSupply(uint256[3] memory rawBalances) public view returns (uint256) {
        return RivenPoolShare(shareToken).totalSupply() - rawBalances[1];
    }

    function quoteExactOutput(uint256[3] memory rawBalances, uint8 indexIn, uint8 indexOut, uint256 rawAmountOut)
        external
        view
        returns (uint256 rawAmountIn)
    {
        require(msg.sender == vault, "vault");
        require(indexIn < 3 && indexOut < 3 && indexIn != indexOut && rawAmountOut != 0, "swap");
        uint256[3] memory factors = scalingFactors();
        uint256[2] memory normalized = [rawBalances[0].mulDown(factors[0]), rawBalances[2].mulDown(factors[2])];
        uint256 invariantValue = RivenStableMath.invariant(amplification, normalized);
        uint256 supply = actualSupply(rawBalances);

        if (indexIn == 1) {
            uint256 normalizedOut = rawAmountOut.mulDown(factors[indexOut]);
            uint8 output = indexOut == 0 ? 0 : 1;
            uint256[2] memory afterExit = normalized;
            afterExit[output] -= normalizedOut;
            uint256 invariantAfter = RivenStableMath.invariant(amplification, afterExit);
            rawAmountIn = (supply * (invariantValue - invariantAfter) + invariantValue - 1) / invariantValue;
        } else if (indexOut == 1) {
            uint8 input = indexIn == 0 ? 0 : 1;
            uint256 invariantAfter = (invariantValue * (supply + rawAmountOut) + supply - 1) / supply;
            uint256 finalBalance = RivenStableMath.balanceAtInvariant(amplification, normalized, invariantAfter, input);
            uint256 normalizedIn = finalBalance - normalized[input] + 1;
            uint256 beforeFee = RivenFixedPoint.divUp(normalizedIn, factors[indexIn]);
            rawAmountIn = RivenFixedPoint.divUp(beforeFee, 1 ether - feePercentage);
        } else {
            uint8 input = indexIn == 0 ? 0 : 1;
            uint8 output = indexOut == 0 ? 0 : 1;
            uint256 normalizedOut = rawAmountOut.mulDown(factors[indexOut]);
            uint256 normalizedIn = RivenStableMath.inputForExactOutput(
                amplification, normalized, input, output, normalizedOut, invariantValue
            );
            uint256 beforeFee = RivenFixedPoint.divUp(normalizedIn, factors[indexIn]);
            rawAmountIn = RivenFixedPoint.divUp(beforeFee, 1 ether - feePercentage);
        }
        require(rawAmountIn != 0, "input");
    }
}
