// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract ProtocolERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }
    function approve(address spender, uint256 amount) public returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) public returns (bool) { _transfer(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        _transfer(from, to, amount);
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: zero recipient");
        balanceOf[from] -= amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal { totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount); }
    function _burn(address from, uint256 amount) internal { balanceOf[from] -= amount; totalSupply -= amount; emit Transfer(from, address(0), amount); }
}

contract SettlementToken is ProtocolERC20 {
    address public administrator;
    constructor() ProtocolERC20("USD Coin", "USDC", 6) { administrator = msg.sender; }
    function mint(address to, uint256 amount) external { require(msg.sender == administrator, "administrator"); _mint(to, amount); }
    function renounceAdministration() external { require(msg.sender == administrator, "administrator"); administrator = address(0); }
}
