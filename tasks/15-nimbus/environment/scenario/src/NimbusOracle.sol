// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

abstract contract NimbusVenueState {
    address public immutable token0;
    address public immutable token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint16 public immutable feeBps;

    constructor(address token0_, address token1_, uint16 feeBps_) {
        token0 = token0_;
        token1 = token1_;
        feeBps = feeBps_;
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function quoteOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        require(tokenIn == token0 || tokenIn == token1, "token");
        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 scaled = amountIn * (10_000 - feeBps);
        return scaled * reserveOut / (reserveIn * 10_000 + scaled);
    }

    function sync() external {
        _sync();
    }

    function _exchange(address tokenIn, uint256 amountIn, uint256 minimumOut, address receiver)
        internal
        returns (uint256 amountOut)
    {
        address tokenOut = tokenIn == token0 ? token1 : token0;
        amountOut = quoteOut(tokenIn, amountIn);
        require(amountOut >= minimumOut, "minimum");
        require(IERC20Like(tokenIn).transferFrom(msg.sender, address(this), amountIn), "input");
        require(IERC20Like(tokenOut).transfer(receiver, amountOut), "output");
        _sync();
    }

    function _sync() private {
        uint256 first = IERC20Like(token0).balanceOf(address(this));
        uint256 second = IERC20Like(token1).balanceOf(address(this));
        require(first <= type(uint112).max && second <= type(uint112).max, "reserves");
        reserve0 = uint112(first);
        reserve1 = uint112(second);
    }
}

contract NimbusStableVenue is NimbusVenueState {
    constructor(address token0_, address token1_) NimbusVenueState(token0_, token1_, 4) {}

    function exchangeExactInput(address tokenIn, uint256 amountIn, uint256 minimumOut, address receiver)
        external
        returns (uint256)
    {
        return _exchange(tokenIn, amountIn, minimumOut, receiver);
    }
}

contract NimbusWeightedVenue is NimbusVenueState {
    constructor(address token0_, address token1_) NimbusVenueState(token0_, token1_, 45) {}

    function trade(bool zeroForOne, uint256 amountIn, uint256 minimumOut, address receiver, bytes calldata data)
        external
        returns (uint256)
    {
        require(data.length == 0, "hook data");
        return _exchange(zeroForOne ? token0 : token1, amountIn, minimumOut, receiver);
    }
}

contract NimbusCompositeOracle {
    struct Source {
        address venue;
        uint16 weight;
        uint16 observationBps;
        uint8 sector;
        uint128 ema;
        uint64 observations;
    }

    address public administrator = msg.sender;
    address public consumer;
    uint256 public cachedPrice = 1 ether;
    Source[] public sources;

    event ConsumerRegistered(address indexed consumer);
    event SourceRegistered(address indexed venue, uint256 indexed index, uint16 weight, uint16 observationBps);

    constructor(address[] memory venues_, uint16[] memory weights_, uint16[] memory observationBps_) {
        require(venues_.length == 127 && weights_.length == venues_.length && observationBps_.length == venues_.length);
        for (uint256 i; i < venues_.length; ++i) {
            require(venues_[i] != address(0) && weights_[i] != 0 && observationBps_[i] <= 10_000, "source");
            sources.push(
                Source(venues_[i], weights_[i], observationBps_[i], uint8((i * 7 + 3) % 9), uint128(1 ether), 0)
            );
            emit SourceRegistered(venues_[i], i, weights_[i], observationBps_[i]);
        }
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function venues(uint256 index) external view returns (address) {
        return sources[index].venue;
    }

    function ema(uint256 index) external view returns (uint256) {
        return sources[index].ema;
    }

    function spotAt(uint256 index) public view returns (uint256) {
        (uint112 cashReserve, uint112 collateralReserve) = LocalPair(sources[index].venue).getReserves();
        return uint256(cashReserve) * 1 ether / uint256(collateralReserve);
    }

    function _sample(uint256 index) private {
        Source storage source = sources[index];
        uint256 spot = spotAt(index);
        uint256 retained = 10_000 - source.observationBps;
        source.ema = uint128((uint256(source.ema) * retained + spot * source.observationBps) / 10_000);
        ++source.observations;
    }

    function sampleAll() external {
        for (uint256 i; i < sources.length; ++i) {
            _sample(i);
        }
        cachedPrice = _aggregatePrice();
    }

    function registerConsumer(address consumer_) external {
        require(msg.sender == administrator && consumer_ != address(0), "administrator");
        consumer = consumer_;
        administrator = address(0);
        emit ConsumerRegistered(consumer_);
    }

    function price() public view returns (uint256) {
        return cachedPrice;
    }

    function _aggregatePrice() private view returns (uint256) {
        uint256[9] memory sectorPrices;
        for (uint8 sector; sector < 9; ++sector) {
            sectorPrices[sector] = _sectorMedian(sector);
        }
        for (uint256 i = 1; i < sectorPrices.length; ++i) {
            uint256 value = sectorPrices[i];
            uint256 j = i;
            while (j != 0 && sectorPrices[j - 1] > value) {
                sectorPrices[j] = sectorPrices[j - 1];
                --j;
            }
            sectorPrices[j] = value;
        }
        return sectorPrices[4];
    }

    function _sectorMedian(uint8 sector) private view returns (uint256) {
        uint256 count = sources.length;
        uint256 memberCount;
        for (uint256 i; i < count; ++i) {
            if (sources[i].sector == sector) ++memberCount;
        }
        uint256[] memory blended = new uint256[](memberCount);
        uint256[] memory weights = new uint256[](memberCount);
        uint256 totalWeight;
        uint256 cursor;
        for (uint256 i; i < count; ++i) {
            Source memory source = sources[i];
            if (source.sector != sector) continue;
            uint256 spot = spotAt(i);
            blended[cursor] = (spot + source.ema) / 2;
            weights[cursor] = source.weight;
            totalWeight += source.weight;
            ++cursor;
        }
        for (uint256 i = 1; i < memberCount; ++i) {
            uint256 value = blended[i];
            uint256 weight = weights[i];
            uint256 j = i;
            while (j != 0 && blended[j - 1] > value) {
                blended[j] = blended[j - 1];
                weights[j] = weights[j - 1];
                --j;
            }
            blended[j] = value;
            weights[j] = weight;
        }
        uint256 cumulative;
        for (uint256 i; i < memberCount; ++i) {
            cumulative += weights[i];
            if (cumulative * 2 >= totalWeight) return blended[i];
        }
        revert("median");
    }
}
