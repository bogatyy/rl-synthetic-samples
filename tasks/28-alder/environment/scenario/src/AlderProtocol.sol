// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./AlderVenues.sol";

contract AlderBasketReserve {
    address public issuance;
    address public immutable registry;

    constructor(address registry_) {
        registry = registry_;
    }

    function bind(address issuance_) external {
        require(issuance == address(0), "bound");
        issuance = issuance_;
    }

    function release(address token, address receiver, uint256 amount) external returns (uint256 released) {
        require(msg.sender == issuance, "issuance");
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        uint256 cap = balance * 9 / 10;
        released = amount > cap ? cap : amount;
        IERC20Like(token).transfer(receiver, released);
    }
}

contract AlderBasketIssuance {
    struct Route {
        address venue;
        uint256 weight;
    }

    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public componentReserve;
    address public liquidityBank;
    address public componentRegistry;
    address public venueFactory;
    address public componentShop;

    function configure(
        address cash,
        address settlementReserve,
        address componentReserve_,
        address bank,
        address registry,
        address factory,
        address shop
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = settlementReserve;
        componentReserve = componentReserve_;
        liquidityBank = bank;
        componentRegistry = registry;
        venueFactory = factory;
        componentShop = shop;
        administrator = address(0);
    }

    function componentCount() external view returns (uint256) {
        return AlderComponentRegistry(componentRegistry).componentCount();
    }

    function component(uint256 index) external view returns (address) {
        return AlderComponentRegistry(componentRegistry).components(index);
    }

    function unitOf(address token) external view returns (uint256) {
        return AlderComponentRegistry(componentRegistry).unitOf(token);
    }

    function issueWithSingleAsset(address input, uint256 amount, Route[] calldata routes) external {
        uint256 count = AlderComponentRegistry(componentRegistry).componentCount();
        require(routes.length == count && amount != 0, "request");
        require(AlderComponentRegistry(componentRegistry).unitOf(input) != 0, "input component");
        IERC20Like(input).transferFrom(msg.sender, address(this), amount);
        for (uint256 i; i < count; ++i) {
            address output = AlderComponentRegistry(componentRegistry).components(i);
            if (output == input) continue;
            address venue = routes[i].venue;
            require(
                AlderVenueFactory(venueFactory).created(venue) && AlderThinVenue(venue).contains(input, output), "venue"
            );
            uint256 quoted = AlderThinVenue(venue).quote(input, amount);
            AlderBasketReserve(componentReserve).release(output, venue, quoted * routes[i].weight / 1 ether);
        }
    }
}
