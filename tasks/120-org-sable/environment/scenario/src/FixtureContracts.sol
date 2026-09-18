// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IFixtureERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address receiver, uint256 amount) external returns (bool);
}

interface IFixtureCrocDex {
    function userCmd(uint16 callpath, bytes calldata cmd) external payable returns (bytes memory);
}

interface IFixtureFlashRecipient {
    function receiveFlashLoan(
        IFixtureERC20[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}

contract FixtureToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    address public administrator = msg.sender;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
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

    function transferFrom(address owner, address receiver, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[owner][msg.sender];
        if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - amount;
        _transfer(owner, receiver, amount);
        return true;
    }

    function mint(address receiver, uint256 amount) external {
        require(msg.sender == administrator, "administrator");
        totalSupply += amount;
        balanceOf[receiver] += amount;
        emit Transfer(address(0), receiver, amount);
    }

    function renounceAdministration() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function _transfer(address owner, address receiver, uint256 amount) private {
        require(receiver != address(0), "receiver");
        balanceOf[owner] -= amount;
        balanceOf[receiver] += amount;
        emit Transfer(owner, receiver, amount);
    }
}

contract FixtureWrappedNative is FixtureToken {
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
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "native transfer");
    }
}

contract FixtureFlashVault {
    uint256 public constant FEE_BPS = 5;

    function flashLoan(
        IFixtureFlashRecipient receiver,
        IFixtureERC20[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(tokens.length == amounts.length && tokens.length != 0, "length");
        uint256[] memory beforeBalances = new uint256[](tokens.length);
        uint256[] memory fees = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            beforeBalances[i] = tokens[i].balanceOf(address(this));
            require(amounts[i] <= beforeBalances[i], "liquidity");
            fees[i] = amounts[i] * FEE_BPS / 10_000;
            require(tokens[i].transfer(address(receiver), amounts[i]), "transfer");
        }
        receiver.receiveFlashLoan(tokens, amounts, fees, data);
        for (uint256 i; i < tokens.length; ++i) {
            require(tokens[i].balanceOf(address(this)) >= beforeBalances[i] + fees[i], "repayment");
        }
    }
}

contract FixtureStateBuilder {
    address public administrator = msg.sender;
    address public immutable dex;

    constructor(address dex_) {
        require(dex_ != address(0), "dex");
        dex = dex_;
    }

    receive() external payable {}

    modifier onlyAdministrator() {
        require(msg.sender == administrator, "administrator");
        _;
    }

    function approveToken(IFixtureERC20 token) external onlyAdministrator {
        require(token.approve(dex, type(uint256).max), "approve");
    }

    function command(uint16 callpath, bytes calldata cmd, uint256 value)
        external
        onlyAdministrator
        returns (bytes memory)
    {
        return IFixtureCrocDex(dex).userCmd{value: value}(callpath, cmd);
    }

    function drainToken(IFixtureERC20 token, address receiver) external onlyAdministrator {
        require(token.transfer(receiver, token.balanceOf(address(this))), "drain token");
    }

    function drainNative(address payable receiver) external onlyAdministrator {
        (bool sent,) = receiver.call{value: address(this).balance}("");
        require(sent, "drain native");
    }

    function renounceAdministration() external onlyAdministrator {
        administrator = address(0);
    }
}

contract FixtureAuthority {
    receive() external payable {}

    function acceptsCrocAuthority() external pure returns (bool) {
        return true;
    }
}
