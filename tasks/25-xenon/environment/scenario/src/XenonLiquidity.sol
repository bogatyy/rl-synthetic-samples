// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IXenonCreditReceiver {
    function onXenonCredit(address lender, address token, uint256 amount, uint256 fee, bytes calldata data) external;
}

interface IXenonPullReceiver {
    function onXenonPull(address lender, address token, uint256 amount, uint256 fee, bytes calldata data) external;
}

interface IXenonSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata data)
        external
        returns (bool);
}

interface IXenonBatchReceiver {
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}

interface IXenonRangeReceiver {
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

contract XenonSimpleBank {
    address public immutable asset;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address asset_, uint16 feeBps_) {
        asset = asset_;
        feeBps = feeBps_;
    }

    function flashLoanSimple(address receiver, address requestedAsset, uint256 amount, bytes calldata data, uint16)
        external
    {
        require(!entered && requestedAsset == asset, "loan");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        uint256 premium = amount * feeBps / 10_000;
        require(IERC20Like(asset).transfer(receiver, amount), "transfer");
        require(
            IXenonSimpleReceiver(receiver).executeOperation(asset, amount, premium, receiver, data), "callback"
        );
        require(IERC20Like(asset).transferFrom(receiver, address(this), amount + premium), "repayment");
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance + premium, "balance");
        entered = false;
    }
}

contract XenonBatchBank {
    address public immutable asset;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address asset_, uint16 feeBps_) {
        asset = asset_;
        feeBps = feeBps_;
    }

    function flashLoan(
        address receiver,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(!entered && tokens.length == 1 && amounts.length == 1 && tokens[0] == asset, "loan");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        uint256[] memory fees = new uint256[](1);
        fees[0] = amounts[0] * feeBps / 10_000;
        require(IERC20Like(asset).transfer(receiver, amounts[0]), "transfer");
        IXenonBatchReceiver(receiver).receiveFlashLoan(tokens, amounts, fees, data);
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance + fees[0], "repayment");
        entered = false;
    }
}

contract XenonRangeBank {
    address public immutable asset;
    bool public immutable assetIsToken0;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address asset_, bool assetIsToken0_, uint16 feeBps_) {
        asset = asset_;
        assetIsToken0 = assetIsToken0_;
        feeBps = feeBps_;
    }

    function flash(address receiver, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(!entered, "entered");
        uint256 amount = assetIsToken0 ? amount0 : amount1;
        require(amount != 0 && (assetIsToken0 ? amount1 == 0 : amount0 == 0), "amounts");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        uint256 fee = amount * feeBps / 10_000;
        require(IERC20Like(asset).transfer(receiver, amount), "transfer");
        IXenonRangeReceiver(receiver).uniswapV3FlashCallback(assetIsToken0 ? fee : 0, assetIsToken0 ? 0 : fee, data);
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance + fee, "repayment");
        entered = false;
    }
}

contract XenonCallbackBank {
    address public immutable asset;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address asset_, uint16 feeBps_) {
        require(asset_ != address(0) && feeBps_ <= 100, "configuration");
        asset = asset_;
        feeBps = feeBps_;
    }

    function borrow(address receiver, uint256 amount, bytes calldata data) external {
        require(!entered, "entered");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        require(amount <= beforeBalance, "liquidity");
        uint256 fee = amount * feeBps / 10_000;
        require(IERC20Like(asset).transfer(receiver, amount), "transfer");
        IXenonCreditReceiver(receiver).onXenonCredit(address(this), asset, amount, fee, data);
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance + fee, "repayment");
        entered = false;
    }
}

contract XenonPullBank {
    address public immutable asset;
    uint16 public immutable feeBps;
    bool private entered;

    constructor(address asset_, uint16 feeBps_) {
        require(asset_ != address(0) && feeBps_ <= 100, "configuration");
        asset = asset_;
        feeBps = feeBps_;
    }

    function draw(address receiver, uint256 amount, bytes calldata data) external {
        require(!entered, "entered");
        entered = true;
        uint256 beforeBalance = IERC20Like(asset).balanceOf(address(this));
        require(amount <= beforeBalance, "liquidity");
        uint256 fee = amount * feeBps / 10_000;
        require(IERC20Like(asset).transfer(receiver, amount), "transfer");
        IXenonPullReceiver(receiver).onXenonPull(address(this), asset, amount, fee, data);
        require(IERC20Like(asset).transferFrom(receiver, address(this), amount + fee), "pull repayment");
        require(IERC20Like(asset).balanceOf(address(this)) >= beforeBalance + fee, "repayment");
        entered = false;
    }
}
