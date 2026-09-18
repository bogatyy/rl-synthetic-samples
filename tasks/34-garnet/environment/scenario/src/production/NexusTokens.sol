// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC20,
    Ownable,
    SafeMath,
    SafeERC20,
    IERC20,
    Address,
    IUniswapV2Factory,
    IUniswapV2Router02
} from "./nexus_dip.sol";

/// @notice Verified AIC behavior from the historical deployment.
contract AIC is ERC20, Ownable {
    using SafeERC20 for IERC20;

    address public devAddr;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        devAddr = msg.sender;
        _mint(owner(), 210_000_000 ether);
    }

    receive() external payable {}

    function claimStuckTokens(address token) external {
        Address.sendValue(payable(devAddr), address(this).balance);
        if (token != address(0)) {
            IERC20(token).safeTransfer(devAddr, IERC20(token).balanceOf(address(this)));
        }
    }
}

/// @notice Verified NEX behavior from the historical deployment.
contract NEX is ERC20, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public uniswapV2Router;
    address public uniswapV2PairAid;
    address public tokenAid;
    address public deadWallet = address(0xdead);
    address public devWallet;

    uint256 public daoFee = 3;
    uint256 public nodeFee = 3;
    address public daoAddress;
    address public nodeAddress;

    mapping(address => bool) public automatedMarketMakerPairs;

    receive() external payable {}

    constructor(address router_, address tokenAid_) ERC20("NEX", "NEX") {
        tokenAid = tokenAid_;
        uniswapV2Router = router_;
        uniswapV2PairAid = IUniswapV2Factory(IUniswapV2Router02(router_).factory()).createPair(
            address(this), tokenAid_
        );
        _setAutomatedMarketMakerPair(uniswapV2PairAid, true);
        devWallet = _msgSender();
        _mint(owner(), 1_000_000_000 ether);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) internal {
        require(automatedMarketMakerPairs[pair] != value, " : Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2PairAid, "The pair cannot be removed from automatedMarketMakerPairs");
        _setAutomatedMarketMakerPair(pair, value);
    }

    function setFee(uint256 daoFee_, uint256 nodeFee_) external onlyOwner {
        require(daoFee_ + nodeFee_ <= 50, " : Fee is too high");
        daoFee = daoFee_;
        nodeFee = nodeFee_;
    }

    function setFeeAddress(address daoAddress_, address nodeAddress_) external onlyOwner {
        require(daoAddress_ != address(0), " : Invalid dao address");
        require(nodeAddress_ != address(0), " : Invalid node address");
        daoAddress = daoAddress_;
        nodeAddress = nodeAddress_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        bool isSell = automatedMarketMakerPairs[to];
        bool isRouter = from == uniswapV2Router || to == uniswapV2Router;
        if (isRouter) {
            super._transfer(from, to, amount);
        } else if (isSell) {
            uint256 daoTokens = amount.mul(daoFee).div(100);
            uint256 nodeTokens = amount.mul(nodeFee).div(100);
            amount = amount.sub(daoTokens).sub(nodeTokens);
            if (daoTokens > 0) super._transfer(from, daoAddress, daoTokens);
            if (nodeTokens > 0) super._transfer(from, nodeAddress, nodeTokens);
        }
        super._transfer(from, to, amount);
    }

    function claimStuckTokens(address token) external {
        Address.sendValue(payable(devWallet), address(this).balance);
        if (token != address(0) && token != address(this)) {
            IERC20(token).safeTransfer(devWallet, IERC20(token).balanceOf(address(this)));
        }
    }
}
