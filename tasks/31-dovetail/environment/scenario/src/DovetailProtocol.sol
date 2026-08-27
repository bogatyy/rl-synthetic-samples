// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./DovetailProduct.sol";
import "./DovetailModules.sol";

contract DovetailExchangePortal {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public baseAsset;
    address public bondAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public productCreator;
    address public basicIssuance;
    address public navRedemption;
    address public canonicalValuer;
    mapping(address => bool) public issuanceActive;

    function configure(
        address cash,
        address base,
        address bond,
        address bank,
        address creator,
        address basic,
        address nav,
        address valuer
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        baseAsset = base;
        bondAsset = bond;
        protectedReserve = address(this);
        liquidityBank = bank;
        productCreator = creator;
        basicIssuance = basic;
        navRedemption = nav;
        canonicalValuer = valuer;
        IERC20Like(cash).approve(basic, type(uint256).max);
        IERC20Like(base).approve(basic, type(uint256).max);
        IERC20Like(bond).approve(basic, type(uint256).max);
        administrator = address(0);
    }

    function issueProductForExactCash(address product, uint256 quantity, address receiver) external {
        DovetailProductToken token = DovetailProductToken(product);
        require(token.components(0) == settlementAsset && token.units(0) == 1 ether, "cash component");
        IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), quantity);
        issuanceActive[product] = true;
        DovetailBasicIssuance(basicIssuance).issue(product, quantity, receiver);
        issuanceActive[product] = false;
    }

    function payNav(address receiver, uint256 amount) external {
        require(msg.sender == navRedemption, "nav module");
        IERC20Like(settlementAsset).transfer(receiver, amount);
    }
}
