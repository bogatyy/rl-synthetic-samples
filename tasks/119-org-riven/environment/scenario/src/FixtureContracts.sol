// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.1;

import "./pool/@balancer-labs/v2-interfaces/contracts/vault/IAuthorizer.sol";
import "./pool/@balancer-labs/v2-interfaces/contracts/pool-utils/IRateProvider.sol";
import "./pool/@balancer-labs/v2-interfaces/contracts/standalone-utils/IProtocolFeePercentagesProvider.sol";

contract FixtureAuthorizer is IAuthorizer {
    address private _administrator;

    constructor() {
        _administrator = msg.sender;
    }

    function canPerform(bytes32, address account, address) external view override returns (bool) {
        return account == _administrator;
    }

    function lock() external {
        require(msg.sender == _administrator, "administrator");
        _administrator = address(0);
    }
}

contract FixtureToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    address private _administrator;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory tokenName, string memory tokenSymbol, uint8 tokenDecimals) {
        name = tokenName;
        symbol = tokenSymbol;
        decimals = tokenDecimals;
        _administrator = msg.sender;
    }

    function mint(address receiver, uint256 amount) external {
        require(msg.sender == _administrator, "administrator");
        totalSupply += amount;
        balanceOf[receiver] += amount;
        emit Transfer(address(0), receiver, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        _transfer(msg.sender, receiver, amount);
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 amount) external returns (bool) {
        if (msg.sender != sender && allowance[sender][msg.sender] != uint256(-1)) {
            uint256 permitted = allowance[sender][msg.sender];
            require(permitted >= amount, "allowance");
            allowance[sender][msg.sender] = permitted - amount;
        }
        _transfer(sender, receiver, amount);
        return true;
    }

    function renounceAdministration() external {
        require(msg.sender == _administrator, "administrator");
        _administrator = address(0);
    }

    function _transfer(address sender, address receiver, uint256 amount) private {
        require(receiver != address(0) && balanceOf[sender] >= amount, "balance");
        balanceOf[sender] -= amount;
        balanceOf[receiver] += amount;
        emit Transfer(sender, receiver, amount);
    }
}

contract FixtureWETH is FixtureToken {
    constructor() FixtureToken("Wrapped Ether", "WETH", 18) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ether");
    }
}

contract FixtureRateProvider is IRateProvider {
    uint256 private _rate;
    address private _administrator;

    constructor(uint256 initialRate) {
        require(initialRate != 0, "rate");
        _rate = initialRate;
        _administrator = msg.sender;
    }

    function getRate() external view override returns (uint256) {
        return _rate;
    }

    function setRate(uint256 nextRate) external {
        require(msg.sender == _administrator && nextRate != 0, "administrator");
        _rate = nextRate;
    }

    function lock() external {
        require(msg.sender == _administrator, "administrator");
        _administrator = address(0);
    }
}

contract FixtureProtocolFeeProvider is IProtocolFeePercentagesProvider {
    function registerFeeType(uint256, string memory, uint256, uint256) external override {}
    function isValidFeeType(uint256 feeType) external view override returns (bool) { return feeType < 4; }
    function isValidFeeTypePercentage(uint256, uint256 value) external view override returns (bool) {
        return value <= 1e18;
    }
    function setFeeTypePercentage(uint256, uint256) external override {}
    function getFeeTypePercentage(uint256) external view override returns (uint256) { return 0; }
    function getFeeTypeMaximumPercentage(uint256) external view override returns (uint256) { return 1e18; }
    function getFeeTypeName(uint256) external view override returns (string memory) { return "fixture"; }
}
