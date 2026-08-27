// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

contract AlderThinVenue {
    address public immutable token0;
    address public immutable token1;
    address public immutable provider;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address token0_, address token1_, address provider_) {
        token0 = token0_;
        token1 = token1_;
        provider = provider_;
    }

    function seed(uint256 amount0, uint256 amount1) external {
        require(msg.sender == provider && reserve0 == 0, "provider");
        IERC20Like(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20Like(token1).transferFrom(msg.sender, address(this), amount1);
        _sync();
    }

    function contains(address input, address output) external view returns (bool) {
        return (input == token0 && output == token1) || (input == token1 && output == token0);
    }

    function quote(address input, uint256 amount) external view returns (uint256 outputAmount) {
        require(input == token0 || input == token1, "input");
        outputAmount = input == token0
            ? amount * uint256(reserve1) / uint256(reserve0)
            : amount * uint256(reserve0) / uint256(reserve1);
    }

    function close(address receiver) external {
        require(msg.sender == provider, "provider");
        IERC20Like(token0).transfer(receiver, IERC20Like(token0).balanceOf(address(this)));
        IERC20Like(token1).transfer(receiver, IERC20Like(token1).balanceOf(address(this)));
        _sync();
    }

    function _sync() private {
        uint256 a = IERC20Like(token0).balanceOf(address(this));
        uint256 b = IERC20Like(token1).balanceOf(address(this));
        require(a <= type(uint112).max && b <= type(uint112).max, "reserves");
        reserve0 = uint112(a);
        reserve1 = uint112(b);
    }
}

contract AlderVenueFactory {
    mapping(address => bool) public created;
    event VenueCreated(address indexed venue, address indexed token0, address indexed token1, address provider);

    function create(address token0, address token1) external returns (address venue) {
        require(token0 != token1, "pair");
        venue = address(new AlderThinVenue(token0, token1, msg.sender));
        created[venue] = true;
        emit VenueCreated(venue, token0, token1, msg.sender);
    }
}

contract AlderComponentShop {
    address public immutable cash;
    address public immutable registry;

    constructor(address cash_, address registry_) {
        cash = cash_;
        registry = registry_;
    }

    function buy(address token, uint256 amount, address receiver) external returns (uint256 cashCost) {
        uint256 unit = AlderComponentRegistry(registry).unitOf(token);
        require(unit != 0, "component");
        cashCost = amount * 1 ether / unit;
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashCost);
        IERC20Like(token).transfer(receiver, amount);
    }

    function sell(address token, uint256 amount, address receiver) external returns (uint256 cashOut) {
        uint256 unit = AlderComponentRegistry(registry).unitOf(token);
        require(unit != 0, "component");
        cashOut = amount * 1 ether / unit;
        IERC20Like(token).transferFrom(msg.sender, address(this), amount);
        IERC20Like(cash).transfer(receiver, cashOut);
    }
}

contract AlderComponentRegistry {
    address[] public components;
    mapping(address => uint8) public decimalsOf;
    mapping(address => uint256) public unitOf;

    constructor(address[] memory components_, uint8[] memory decimals_) {
        require(components_.length == 8 && decimals_.length == 8, "components");
        for (uint256 i; i < components_.length; ++i) {
            components.push(components_[i]);
            decimalsOf[components_[i]] = decimals_[i];
            unitOf[components_[i]] = 10 ** decimals_[i];
        }
    }

    function componentCount() external view returns (uint256) {
        return components.length;
    }
}
