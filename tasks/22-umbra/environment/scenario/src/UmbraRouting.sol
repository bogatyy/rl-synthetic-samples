// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IUmbraAdapter {
    function metadata() external view returns (address input, address output, uint8 routeType);
    function execute(uint256 amount, address receiver, bytes calldata data) external returns (uint256 reported);
}

contract UmbraVenueRegistry {
    address public immutable factory;
    mapping(address => bool) public approved;
    event VenueApproved(address indexed adapter, address indexed input, address indexed output, uint8 routeType);

    constructor(address factory_) {
        factory = factory_;
    }

    function register(address adapter) external {
        require(UmbraAdapterFactory(factory).isAdapter(adapter), "factory");
        (address input, address output, uint8 routeType) = IUmbraAdapter(adapter).metadata();
        require(input != address(0) && output != address(0) && input != output && routeType < 3, "metadata");
        approved[adapter] = true;
        emit VenueApproved(adapter, input, output, routeType);
    }
}

contract UmbraAdapterProxy {
    address public immutable input;
    address public immutable output;
    address public immutable plugin;
    uint8 public immutable routeType;

    constructor(address input_, address output_, address plugin_, uint8 routeType_) {
        input = input_;
        output = output_;
        plugin = plugin_;
        routeType = routeType_;
    }

    function metadata() external view returns (address, address, uint8) {
        return (input, output, routeType);
    }

    function execute(uint256 amount, address receiver, bytes calldata data) external returns (uint256 reported) {
        (bool ok, bytes memory out) = plugin.delegatecall(
            abi.encodeWithSignature("route(uint256,address,bytes)", amount, receiver, data)
        );
        if (!ok) assembly {
            revert(add(out, 32), mload(out))
        }
        reported = abi.decode(out, (uint256));
    }
}

contract UmbraAdapterFactory {
    mapping(address => bool) public isAdapter;
    event AdapterCreated(
        address indexed adapter, address indexed input, address indexed output, address plugin, uint8 routeType
    );

    function create(address input, address output, address plugin, uint8 routeType) external returns (address adapter) {
        require(plugin.code.length != 0, "plugin");
        adapter = address(new UmbraAdapterProxy(input, output, plugin, routeType));
        isAdapter[adapter] = true;
        emit AdapterCreated(adapter, input, output, plugin, routeType);
    }
}

contract UmbraRouteExecutor {
    struct Hop {
        address adapter;
        bytes data;
    }

    address public immutable registry;

    constructor(address registry_) {
        registry = registry_;
    }

    function execute(address input, uint256 amount, Hop[] calldata hops, address receiver)
        external
        returns (address output, uint256 settled)
    {
        require(hops.length == 2 && receiver != address(0), "route");
        address cursor = input;
        uint256 running = amount;
        for (uint256 i; i < hops.length; ++i) {
            address adapter = hops[i].adapter;
            require(UmbraVenueRegistry(registry).approved(adapter), "adapter");
            (address tokenIn, address tokenOut, uint8 routeType) = IUmbraAdapter(adapter).metadata();
            require(tokenIn == cursor, "continuity");
            address recipient = i + 1 == hops.length ? receiver : address(this);
            uint256 beforeBalance = IERC20Like(tokenOut).balanceOf(recipient);
            IERC20Like(tokenIn).transfer(adapter, running);
            uint256 reported = IUmbraAdapter(adapter).execute(running, recipient, hops[i].data);
            uint256 actual = IERC20Like(tokenOut).balanceOf(recipient) - beforeBalance;
            running = routeType == 2 ? reported : actual;
            cursor = tokenOut;
        }
        return (cursor, running);
    }
}

contract UmbraFixedPlugin {
    address public immutable inputToken;
    address public immutable outputToken;

    constructor(address input_, address output_) {
        inputToken = input_;
        outputToken = output_;
    }

    function route(uint256 amount, address receiver, bytes calldata) external returns (uint256) {
        IERC20Like(outputToken).transfer(receiver, amount);
        return amount;
    }
}
