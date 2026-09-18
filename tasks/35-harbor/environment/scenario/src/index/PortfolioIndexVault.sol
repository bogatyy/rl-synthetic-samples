// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProtocolERC20} from "../token/ProtocolERC20.sol";

interface IComponentShare {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract PortfolioIndexVault is ProtocolERC20 {
    address public governor;
    address public guardian;
    bytes32 public strategyId;
    uint64 public initializedAt;
    uint64 public rebalanceNonce;
    bool public paused;
    address[] private basket;
    mapping(address => uint16) public targetWeightBps;
    mapping(address => bool) public isComponent;

    event ComponentConfigured(uint256 indexed index, address indexed component, uint16 targetWeightBps);
    event PortfolioInitialized(bytes32 indexed strategyId, address indexed governor, address indexed guardian);
    event Claimed(address indexed account, uint256 burnedShares);
    event Minted(address indexed account, uint256 mintedShares);
    event RebalanceCommitted(uint64 indexed nonce, bytes32 commitment);

    constructor() ProtocolERC20("Thetanuts Index USDC PUT", "TN-IDX-USDC-PUT", 18) {
        governor = msg.sender;
    }

    modifier onlyGovernor() { require(msg.sender == governor, "governor"); _; }

    function initialize(address[] calldata components, uint16[] calldata weights, bytes32 strategyId_, address guardian_) external onlyGovernor {
        require(initializedAt == 0 && components.length == 5 && weights.length == components.length, "initialize");
        uint256 totalWeight;
        for (uint256 i; i < components.length; ++i) {
            require(components[i] != address(0) && !isComponent[components[i]], "component");
            basket.push(components[i]);
            isComponent[components[i]] = true;
            targetWeightBps[components[i]] = weights[i];
            totalWeight += weights[i];
            emit ComponentConfigured(i, components[i], weights[i]);
        }
        require(totalWeight == 10_000, "weights");
        strategyId = strategyId_;
        guardian = guardian_;
        initializedAt = uint64(block.timestamp);
        emit PortfolioInitialized(strategyId_, msg.sender, guardian_);
    }

    function componentCount() external view returns (uint256) { return basket.length; }

    function mint(uint256 amount) external {
        require(!paused && initializedAt != 0 && amount != 0, "mint disabled");
        uint256 supply = totalSupply;
        for (uint256 i; i < basket.length; ++i) {
            IComponentShare component = IComponentShare(basket[i]);
            uint256 required = supply == 0
                ? amount * targetWeightBps[basket[i]] / 10_000
                : component.balanceOf(address(this)) * amount / supply;
            if (required != 0) require(component.transferFrom(msg.sender, address(this), required), "component transfer");
        }
        _mint(msg.sender, amount);
        emit Minted(msg.sender, amount);
    }

    function claim(uint256 amount) external {
        require(!paused && amount != 0, "claim disabled");
        uint256 supply = totalSupply;
        require(amount <= balanceOf[msg.sender] && amount < supply, "claim amount");
        _burn(msg.sender, amount);
        for (uint256 i; i < basket.length; ++i) {
            IComponentShare component = IComponentShare(basket[i]);
            uint256 output = component.balanceOf(address(this)) * amount / supply;
            if (output != 0) require(component.transfer(msg.sender, output), "component output");
        }
        emit Claimed(msg.sender, amount);
    }

    function commitRebalance(bytes32 commitment) external onlyGovernor {
        unchecked { ++rebalanceNonce; }
        emit RebalanceCommitted(rebalanceNonce, commitment);
    }
    function setPaused(bool state) external { require(msg.sender == guardian || msg.sender == governor, "guardian"); paused = state; }
    function transferGovernance(address next) external onlyGovernor { require(next != address(0), "zero"); governor = next; }
}
