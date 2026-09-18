// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20Market {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ISyncPair { function sync() external; }
interface IMoolahReceiver { function onMoolahFlashLoan(uint256 assets, bytes calldata data) external; }

contract MarketPair {
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 private unlocked = 1;

    event Sync(uint112 reserve0, uint112 reserve1);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to);

    modifier lock() { require(unlocked == 1, "Pancake: LOCKED"); unlocked = 0; _; unlocked = 1; }

    constructor(address token0_, address token1_) { token0 = token0_; token1 = token1_; }
    function getReserves() external view returns (uint112, uint112, uint32) { return (reserve0, reserve1, blockTimestampLast); }
    function sync() external lock { _update(); }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external lock {
        require(amount0Out != 0 || amount1Out != 0, "Pancake: output");
        require(amount0Out < reserve0 && amount1Out < reserve1, "Pancake: liquidity");
        if (amount0Out != 0) IERC20Market(token0).transfer(to, amount0Out);
        if (amount1Out != 0) IERC20Market(token1).transfer(to, amount1Out);
        uint256 balance0 = IERC20Market(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Market(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > uint256(reserve0) - amount0Out ? balance0 - (uint256(reserve0) - amount0Out) : 0;
        uint256 amount1In = balance1 > uint256(reserve1) - amount1Out ? balance1 - (uint256(reserve1) - amount1Out) : 0;
        require(amount0In != 0 || amount1In != 0, "Pancake: input");
        uint256 adjusted0 = balance0 * 10_000 - amount0In * 25;
        uint256 adjusted1 = balance1 * 10_000 - amount1In * 25;
        require(adjusted0 * adjusted1 >= uint256(reserve0) * uint256(reserve1) * 100_000_000, "Pancake: K");
        _update();
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function _update() private {
        uint256 balance0 = IERC20Market(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Market(token1).balanceOf(address(this));
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "overflow");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }
}

contract MarketRouter {
    MarketPair public immutable pair;
    constructor(address pair_) { pair = MarketPair(pair_); }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountWithFee = amountIn * 9_975;
        return amountWithFee * reserveOut / (reserveIn * 10_000 + amountWithFee);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp && path.length == 2, "route");
        require(
            (path[0] == pair.token0() && path[1] == pair.token1()) ||
            (path[0] == pair.token1() && path[1] == pair.token0()),
            "market"
        );
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 beforeInput = IERC20Market(path[0]).balanceOf(address(pair));
        IERC20Market(path[0]).transferFrom(msg.sender, address(pair), amountIn);
        uint256 received = IERC20Market(path[0]).balanceOf(address(pair)) - beforeInput;
        uint256 output;
        if (path[0] == pair.token0()) {
            output = getAmountOut(received, reserve0, reserve1);
            require(output >= amountOutMin, "minimum");
            pair.swap(0, output, to, "");
        } else {
            output = getAmountOut(received, reserve1, reserve0);
            require(output >= amountOutMin, "minimum");
            pair.swap(output, 0, to, "");
        }
    }
}

contract MoolahFlashLender {
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20Market asset = IERC20Market(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        require(assets <= beforeBalance, "liquidity");
        asset.transfer(msg.sender, assets);
        IMoolahReceiver(msg.sender).onMoolahFlashLoan(assets, data);
        asset.transferFrom(msg.sender, address(this), assets);
        require(asset.balanceOf(address(this)) >= beforeBalance, "unpaid");
    }
}

contract FixtureStable {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public administrator = msg.sender;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) external returns (bool) { _move(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) { uint256 a = allowance[from][msg.sender]; if (a != type(uint256).max) allowance[from][msg.sender] = a - amount; _move(from, to, amount); return true; }
    function mint(address to, uint256 amount) external { require(msg.sender == administrator, "administrator"); totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount); }
    function renounceAdministration() external { require(msg.sender == administrator, "administrator"); administrator = address(0); }
    function _move(address from, address to, uint256 amount) private { balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); }
}

contract LockedAuthority { receive() external payable {} }
