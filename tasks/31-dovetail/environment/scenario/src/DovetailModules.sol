// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./DovetailProduct.sol";

interface IDovetailIssueHook {
    function beforeIssue(address product, uint256 quantity, address recipient) external;
    function afterIssue(address product, uint256 quantity, address recipient) external;
}

interface IDovetailValuer {
    function value(address product, address reserve) external view returns (uint256);
}

interface IDovetailPortalState {
    function issuanceActive(address product) external view returns (bool);
    function canonicalValuer() external view returns (address);
    function payNav(address receiver, uint256 amount) external;
}

contract DovetailBalanceValuer {
    address public administrator = msg.sender;
    mapping(address => uint256) public price;

    function setPrice(address component, uint256 value) external {
        require(msg.sender == administrator && component != address(0) && value != 0, "price");
        price[component] = value;
    }

    function freeze() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function value(address product, address) external view returns (uint256 unitValue) {
        DovetailProductToken token = DovetailProductToken(product);
        uint256 supply = token.totalSupply();
        require(supply != 0, "supply");
        uint256 gross;
        for (uint256 i; i < token.componentCount(); ++i) {
            address component = token.components(i);
            uint256 componentPrice = price[component];
            require(componentPrice != 0, "component price");
            gross += IERC20Like(component).balanceOf(product) * componentPrice / 1 ether;
        }
        unitValue = gross * 1 ether / supply;
    }
}

contract DovetailBasicIssuance {
    mapping(address => address) public hook;
    mapping(address => bool) public initialized;

    function initialize(address product, address hook_) external {
        require(DovetailProductToken(product).manager() == msg.sender && !initialized[product], "manager");
        initialized[product] = true;
        hook[product] = hook_;
    }

    function updateHook(address product, address hook_) external {
        require(DovetailProductToken(product).manager() == msg.sender && initialized[product], "manager");
        hook[product] = hook_;
    }

    function issue(address product, uint256 quantity, address recipient) external {
        require(initialized[product] && quantity != 0, "issuance");
        DovetailProductToken token = DovetailProductToken(product);
        for (uint256 i; i < token.componentCount(); ++i) {
            uint256 amount = quantity * token.units(i) / 1 ether;
            IERC20Like(token.components(i)).transferFrom(msg.sender, product, amount);
        }
        address callback = hook[product];
        if (callback != address(0)) IDovetailIssueHook(callback).beforeIssue(product, quantity, recipient);
        token.mint(recipient, quantity);
        if (callback != address(0)) IDovetailIssueHook(callback).afterIssue(product, quantity, recipient);
    }

    function redeem(address product, uint256 quantity, address receiver) external {
        DovetailProductToken(product).burn(msg.sender, quantity);
        DovetailProductToken(product).releaseComponents(receiver, quantity);
    }
}

contract DovetailNavRedemption {
    struct Settings {
        address valuer;
        address reserve;
        address portal;
        uint128 redemptionLimit;
    }

    mapping(address => Settings) public settings;
    mapping(address => uint256) public redeemed;

    function initialize(address product, address reserve, address portal, uint128 limit) external {
        require(
            DovetailProductToken(product).manager() == msg.sender && settings[product].valuer == address(0), "manager"
        );
        require(portal != address(0) && limit != 0, "settings");
        address valuer = IDovetailPortalState(portal).canonicalValuer();
        require(valuer != address(0), "valuer");
        settings[product] = Settings(valuer, reserve, portal, limit);
    }

    function redeem(address product, uint256 quantity, address receiver) external {
        Settings memory setting = settings[product];
        require(IDovetailPortalState(setting.portal).issuanceActive(product), "issuance window");
        DovetailProductToken(product).burn(msg.sender, quantity);
        uint256 amount = quantity * IDovetailValuer(setting.valuer).value(product, setting.reserve) / 1 ether;
        require(redeemed[product] + amount <= setting.redemptionLimit, "redemption limit");
        redeemed[product] += amount;
        IDovetailPortalState(setting.portal).payNav(receiver, amount);
    }
}
