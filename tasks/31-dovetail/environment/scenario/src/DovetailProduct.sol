// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

contract DovetailProductToken {
    string public name;
    string public symbol;
    address public immutable manager;
    address[] public components;
    uint256[] public units;
    mapping(address => bool) public modules;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(
        address manager_,
        address[] memory components_,
        uint256[] memory units_,
        address[] memory modules_,
        string memory name_,
        string memory symbol_
    ) {
        require(components_.length == 3 && units_.length == 3, "components");
        manager = manager_;
        components = components_;
        units = units_;
        name = name_;
        symbol = symbol_;
        for (uint256 i; i < modules_.length; ++i) modules[modules_[i]] = true;
    }

    function componentCount() external view returns (uint256) {
        return components.length;
    }

    function mint(address receiver, uint256 quantity) external {
        require(modules[msg.sender], "module");
        totalSupply += quantity;
        balanceOf[receiver] += quantity;
    }

    function burn(address owner, uint256 quantity) external {
        require(modules[msg.sender], "module");
        balanceOf[owner] -= quantity;
        totalSupply -= quantity;
    }

    function releaseComponents(address receiver, uint256 quantity) external {
        require(modules[msg.sender], "module");
        for (uint256 i; i < components.length; ++i) {
            IERC20Like(components[i]).transfer(receiver, quantity * units[i] / 1 ether);
        }
    }
}

contract DovetailProductCreator {
    event ProductCreated(address indexed product, address indexed manager, bytes32 componentHash);

    function create(
        address[] calldata components,
        uint256[] calldata units,
        address[] calldata modules,
        address manager,
        string calldata name,
        string calldata symbol
    ) external returns (address product) {
        require(manager != address(0), "manager");
        product = address(new DovetailProductToken(manager, components, units, modules, name, symbol));
        emit ProductCreated(product, manager, keccak256(abi.encode(components, units)));
    }
}
