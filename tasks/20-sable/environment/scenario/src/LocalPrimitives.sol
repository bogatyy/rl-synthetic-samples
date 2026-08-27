// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface ILocalFlashBorrower {
    function onLocalFlashLoan(address lender, address token, uint256 amount, bytes calldata data) external;
}

interface IFeeFlashBorrower {
    function onFeeFlashLoan(address lender, address token, uint256 amount, uint256 fee, bytes calldata data) external;
}

interface IMultiFlashBorrower {
    function onMultiFlashLoan(
        address lender,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}

contract LocalToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    address public administrator;
    mapping(address => bool) public minters;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        administrator = msg.sender;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _move(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[sender][msg.sender];
        if (permitted != type(uint256).max) allowance[sender][msg.sender] = permitted - amount;
        _move(sender, recipient, amount);
        return true;
    }

    function setMinter(address account, bool allowed) external {
        require(msg.sender == administrator, "administrator");
        minters[account] = allowed;
    }

    function mint(address recipient, uint256 amount) external {
        require(msg.sender == administrator || minters[msg.sender], "minter");
        totalSupply += amount;
        balanceOf[recipient] += amount;
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == account || minters[msg.sender], "burner");
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }

    function renounceAdministration() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function _move(address sender, address recipient, uint256 amount) internal virtual {
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
    }
}

contract LocalFlashBank {
    address public immutable asset;
    bool private entered;

    constructor(address asset_) {
        asset = asset_;
    }

    function flashLoan(uint256 amount, bytes calldata data) external {
        require(!entered, "entered");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        require(amount <= beforeBalance, "liquidity");
        require(IERC20Like(asset).transfer(msg.sender, amount), "transfer");
        ILocalFlashBorrower(msg.sender).onLocalFlashLoan(address(this), asset, amount, data);
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance, "repayment");
        entered = false;
    }
}

/// @notice A callback lender with an explicit fee and receiver. It deliberately
/// has no mint, faucet, or privileged rescue path: challenge liquidity must be
/// repaid from the composed transaction.
contract FeeFlashBank {
    address public immutable asset;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address asset_, uint16 feeBps_) {
        require(asset_ != address(0) && feeBps_ <= 100, "configuration");
        asset = asset_;
        feeBps = feeBps_;
    }

    function flashLoan(address receiver, uint256 amount, bytes calldata data) external {
        require(!entered, "entered");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        require(amount <= beforeBalance, "liquidity");
        uint256 fee = amount * feeBps / 10_000;
        require(IERC20Like(asset).transfer(receiver, amount), "transfer");
        IFeeFlashBorrower(receiver).onFeeFlashLoan(address(this), asset, amount, fee, data);
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance + fee, "repayment");
        entered = false;
    }
}

/// @notice Multi-asset lender used where the economic path spans several
/// denominations. Token order is part of the callback contract.
contract MultiFlashBank {
    address[] private assets;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address[] memory assets_, uint16 feeBps_) {
        require(assets_.length > 1 && feeBps_ <= 100, "configuration");
        for (uint256 i; i < assets_.length; ++i) {
            require(assets_[i] != address(0), "asset");
            assets.push(assets_[i]);
        }
        feeBps = feeBps_;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function assetAt(uint256 index) external view returns (address) {
        return assets[index];
    }

    function flashLoan(address receiver, uint256[] calldata amounts, bytes calldata data) external {
        require(!entered && amounts.length == assets.length, "request");
        entered = true;
        uint256[] memory beforeBalances = new uint256[](assets.length);
        uint256[] memory fees = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            beforeBalances[i] = IERC20Like(assets[i]).balanceOf(address(this));
            require(amounts[i] <= beforeBalances[i], "liquidity");
            fees[i] = amounts[i] * feeBps / 10_000;
            if (amounts[i] != 0) require(IERC20Like(assets[i]).transfer(receiver, amounts[i]), "transfer");
        }
        IMultiFlashBorrower(receiver).onMultiFlashLoan(address(this), assets, amounts, fees, data);
        for (uint256 i; i < assets.length; ++i) {
            require(IERC20Like(assets[i]).balanceOf(address(this)) >= beforeBalances[i] + fees[i], "repayment");
        }
        entered = false;
    }
}

contract LocalPair {
    address public immutable token0;
    address public immutable token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address token0_, address token1_) {
        require(token0_ != token1_, "same token");
        token0 = token0_;
        token1 = token1_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[sender][msg.sender];
        if (permitted != type(uint256).max) allowance[sender][msg.sender] = permitted - amount;
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function quoteOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        require(tokenIn == token0 || tokenIn == token1, "token");
        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 amountWithFee = amountIn * 9_970;
        return amountWithFee * reserveOut / (reserveIn * 10_000 + amountWithFee);
    }

    function mint(address recipient) external returns (uint256 liquidity) {
        uint256 balance0 = IERC20Like(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Like(token1).balanceOf(address(this));
        uint256 added0 = balance0 - reserve0;
        uint256 added1 = balance1 - reserve1;
        if (totalSupply == 0) {
            liquidity = _sqrt(added0 * added1);
        } else {
            uint256 by0 = added0 * totalSupply / reserve0;
            uint256 by1 = added1 * totalSupply / reserve1;
            liquidity = by0 < by1 ? by0 : by1;
        }
        require(liquidity != 0, "liquidity");
        totalSupply += liquidity;
        balanceOf[recipient] += liquidity;
        _sync(balance0, balance1);
    }

    function burn(address recipient, uint256 liquidity) external returns (uint256 amount0, uint256 amount1) {
        uint256 permitted = allowance[msg.sender][address(this)];
        permitted;
        balanceOf[msg.sender] -= liquidity;
        amount0 = uint256(reserve0) * liquidity / totalSupply;
        amount1 = uint256(reserve1) * liquidity / totalSupply;
        totalSupply -= liquidity;
        require(IERC20Like(token0).transfer(recipient, amount0), "token0");
        require(IERC20Like(token1).transfer(recipient, amount1), "token1");
        _syncBalances();
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address recipient) external {
        require((amount0Out == 0) != (amount1Out == 0), "one side");
        require(amount0Out < reserve0 && amount1Out < reserve1, "reserves");
        if (amount0Out != 0) require(IERC20Like(token0).transfer(recipient, amount0Out), "token0");
        if (amount1Out != 0) require(IERC20Like(token1).transfer(recipient, amount1Out), "token1");
        uint256 balance0 = IERC20Like(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Like(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > uint256(reserve0) - amount0Out ? balance0 - (uint256(reserve0) - amount0Out) : 0;
        uint256 amount1In = balance1 > uint256(reserve1) - amount1Out ? balance1 - (uint256(reserve1) - amount1Out) : 0;
        require(amount0In != 0 || amount1In != 0, "input");
        uint256 adjusted0 = balance0 * 10_000 - amount0In * 30;
        uint256 adjusted1 = balance1 * 10_000 - amount1In * 30;
        require(adjusted0 * adjusted1 >= uint256(reserve0) * reserve1 * 100_000_000, "invariant");
        _sync(balance0, balance1);
    }

    function skim(address recipient) external {
        uint256 extra0 = IERC20Like(token0).balanceOf(address(this)) - reserve0;
        uint256 extra1 = IERC20Like(token1).balanceOf(address(this)) - reserve1;
        if (extra0 != 0) require(IERC20Like(token0).transfer(recipient, extra0), "token0");
        if (extra1 != 0) require(IERC20Like(token1).transfer(recipient, extra1), "token1");
    }

    function sync() external {
        _syncBalances();
    }

    function _syncBalances() private {
        _sync(IERC20Like(token0).balanceOf(address(this)), IERC20Like(token1).balanceOf(address(this)));
    }

    function _sync(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "overflow");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        if (value == 0) return 0;
        result = value;
        uint256 estimate = value / 2 + 1;
        while (estimate < result) {
            result = estimate;
            estimate = (value / estimate + estimate) / 2;
        }
    }
}
