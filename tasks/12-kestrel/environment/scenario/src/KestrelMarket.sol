// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

contract KestrelStablePool {
    address public immutable cash;
    address public immutable bond;
    uint112 public cashReserve;
    uint112 public bondReserve;

    constructor(address cash_, address bond_) {
        cash = cash_;
        bond = bond_;
    }

    function seed(uint256 cashAmount, uint256 bondAmount) external {
        require(cashReserve == 0 && bondReserve == 0, "seeded");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(bond).transferFrom(msg.sender, address(this), bondAmount);
        _sync();
    }

    function cashForExactBond(uint256 bondOut) public view returns (uint256 cashIn) {
        require(bondOut != 0 && bondOut < bondReserve, "output");
        uint256 numerator = uint256(cashReserve) * bondOut * 10_000;
        uint256 denominator = (uint256(bondReserve) - bondOut) * 9_970;
        cashIn = numerator / denominator + 1;
    }

    function buyExactBond(uint256 bondOut, uint256 maximumCash, address receiver)
        external
        returns (uint256 cashIn)
    {
        cashIn = cashForExactBond(bondOut);
        require(cashIn <= maximumCash, "slippage");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashIn);
        IERC20Like(bond).transfer(receiver, bondOut);
        _sync();
    }

    function _sync() private {
        uint256 c = IERC20Like(cash).balanceOf(address(this));
        uint256 b = IERC20Like(bond).balanceOf(address(this));
        require(c <= type(uint112).max && b <= type(uint112).max, "reserves");
        cashReserve = uint112(c);
        bondReserve = uint112(b);
    }
}
