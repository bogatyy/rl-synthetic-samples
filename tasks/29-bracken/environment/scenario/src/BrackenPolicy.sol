// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

library BrackenPlanData {
    function code(uint256 index) internal pure returns (uint64 value) {
        uint256 entropy = uint256(keccak256(abi.encode("Bracken withdrawal allocation", index)));
        value = uint64(uint16(500 + entropy % 4_001));
        value |= uint64(uint16(1_000 + (entropy >> 48) % 49_001)) << 16;
        value |= uint64(uint16(1_000 + (entropy >> 96) % 49_001)) << 32;
        value |= uint64(uint16(1_000 + (entropy >> 144) % 49_001)) << 48;
    }
}

contract BrackenWithdrawalPolicy {
    address public immutable bond;
    address public immutable bondStrategy;
    uint8 public immutable requiredEntries;
    uint256 public immutable requiredLiquidity;
    uint256 public immutable requiredDuration;
    uint256 public immutable requiredLoss;
    uint256 public immutable requiredCorrelation;

    mapping(address => uint8) public entryCount;
    mapping(address => uint256) public totalLiquidity;
    mapping(address => uint256) public totalDuration;
    mapping(address => uint256) public totalLoss;
    mapping(address => uint256) public totalCorrelation;
    mapping(address => mapping(uint256 => bool)) public selected;

    constructor(
        address bond_,
        address bondStrategy_,
        uint8 entries,
        uint256 liquidity,
        uint256 duration,
        uint256 loss,
        uint256 correlation
    ) {
        require(
            bond_ != address(0) && bondStrategy_ != address(0) && entries != 0 && liquidity != 0 && duration != 0
                && loss != 0 && correlation != 0,
            "configuration"
        );
        bond = bond_;
        bondStrategy = bondStrategy_;
        requiredEntries = entries;
        requiredLiquidity = liquidity;
        requiredDuration = duration;
        requiredLoss = loss;
        requiredCorrelation = correlation;
    }

    function planCode(uint256 index) external pure returns (uint64) {
        require(index < 512, "index");
        return BrackenPlanData.code(index);
    }

    function include(uint256 index, uint64 code) external {
        require(index < 512 && code == BrackenPlanData.code(index) && !selected[msg.sender][index], "entry");
        require(entryCount[msg.sender] < requiredEntries, "plan full");
        selected[msg.sender][index] = true;
        ++entryCount[msg.sender];
        totalLiquidity[msg.sender] += uint16(code);
        totalDuration[msg.sender] += uint16(code >> 16);
        totalLoss[msg.sender] += uint16(code >> 32);
        totalCorrelation[msg.sender] += uint16(code >> 48);
        require(IERC20Like(bond).transferFrom(msg.sender, bondStrategy, uint256(uint16(code)) * 1e6), "allocation");
    }

    function cleared(address account) external view returns (bool) {
        return entryCount[account] == requiredEntries && totalLiquidity[account] == requiredLiquidity
            && totalDuration[account] == requiredDuration && totalLoss[account] == requiredLoss
            && totalCorrelation[account] == requiredCorrelation;
    }
}
