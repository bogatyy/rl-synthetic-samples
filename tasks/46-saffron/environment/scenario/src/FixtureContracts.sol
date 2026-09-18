// SPDX-License-Identifier: MIT
pragma solidity =0.5.16;

interface IFixtureToken {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IFixturePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address recipient) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address recipient, bytes calldata data) external;
}

interface IFixtureFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IMetaverseAdministration {
    function renounceMinter() external;
}

contract FixtureToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public administrator;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) public {
        name = name_;
        symbol = symbol_;
        administrator = msg.sender;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[sender][msg.sender];
        require(permitted >= amount, "allowance");
        if (permitted != uint256(-1)) allowance[sender][msg.sender] = permitted - amount;
        _transfer(sender, recipient, amount);
        return true;
    }

    function mint(address recipient, uint256 amount) external {
        require(msg.sender == administrator, "administrator");
        totalSupply += amount;
        balanceOf[recipient] += amount;
        emit Transfer(address(0), recipient, amount);
    }

    function renounceAdministration() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(recipient != address(0), "recipient");
        require(balanceOf[sender] >= amount, "balance");
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }
}

contract FixtureDistribution {
    address public administrator;
    address public token;
    mapping(address => bool) private _white;

    constructor(address token_) public {
        administrator = msg.sender;
        token = token_;
    }

    function isWhite(address account) external view returns (bool) {
        return _white[account];
    }

    function setWhite(address account, bool allowed) external {
        require(msg.sender == administrator, "administrator");
        _white[account] = allowed;
    }

    function sendAsset(address asset, address recipient, uint256 amount) external {
        require(msg.sender == administrator, "administrator");
        require(IFixtureToken(asset).transfer(recipient, amount), "transfer");
    }

    function finish(address) external {
        require(msg.sender == administrator, "administrator");
        IMetaverseAdministration(token).renounceMinter();
        administrator = address(0);
    }
}

contract FixtureRouter {
    address public factory;
    uint256 public routedVolume;

    constructor(address factory_) public {
        factory = factory_;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp && path.length == 2, "route");
        address pair = IFixtureFactory(factory).getPair(path[0], path[1]);
        require(pair != address(0), "pair");
        require(IFixtureToken(path[0]).transferFrom(msg.sender, pair, amountIn), "input");

        (uint112 reserve0, uint112 reserve1,) = IFixturePair(pair).getReserves();
        bool inputIs0 = path[0] == IFixturePair(pair).token0();
        uint256 reserveIn = inputIs0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = inputIs0 ? uint256(reserve1) : uint256(reserve0);
        uint256 balanceIn = IFixtureToken(path[0]).balanceOf(pair);
        uint256 actualInput = balanceIn - reserveIn;
        uint256 amountInWithFee = actualInput * 9975;
        uint256 amountOut = amountInWithFee * reserveOut / (reserveIn * 10000 + amountInWithFee);
        require(amountOut >= amountOutMin, "minimum output");
        IFixturePair(pair).swap(inputIs0 ? 0 : amountOut, inputIs0 ? amountOut : 0, recipient, "");
        routedVolume += actualInput;
    }
}

interface IFixtureFlashBorrower {
    function onMoolahFlashLoan(uint256 amount, bytes calldata data) external;
}

contract FixtureFlashLender {
    address public asset;
    uint256 public loans;

    constructor(address asset_) public {
        asset = asset_;
    }

    function flashLoan(address token, uint256 amount, bytes calldata data) external {
        require(token == asset && amount <= IFixtureToken(asset).balanceOf(address(this)), "liquidity");
        uint256 beforeBalance = IFixtureToken(asset).balanceOf(address(this));
        require(IFixtureToken(asset).transfer(msg.sender, amount), "lend");
        IFixtureFlashBorrower(msg.sender).onMoolahFlashLoan(amount, data);
        require(IFixtureToken(asset).transferFrom(msg.sender, address(this), amount), "repay");
        require(IFixtureToken(asset).balanceOf(address(this)) >= beforeBalance, "shortfall");
        loans += 1;
    }
}
