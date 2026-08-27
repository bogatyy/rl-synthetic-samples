// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract SableClearingPolicy {
    address public administrator = msg.sender;
    address public engine;
    uint8 public requiredSettlements;
    uint256 public requiredRiskA;
    uint256 public requiredRiskB;
    uint256 public requiredRiskC;
    uint256 public requiredRiskD;
    mapping(uint256 => uint80) public riskCode;
    mapping(address => mapping(uint256 => bool)) public settled;
    mapping(address => uint8) public settlementCount;
    mapping(address => uint256) public settledRiskA;
    mapping(address => uint256) public settledRiskB;
    mapping(address => uint256) public settledRiskC;
    mapping(address => uint256) public settledRiskD;

    event PoolRegistered(uint256 indexed pool, uint80 riskCode);

    function registerPool(uint256 pool, uint80 code) external {
        require(
            msg.sender == administrator && riskCode[pool] == 0 && uint16(code) != 0 && uint16(code >> 16) != 0
                && uint16(code >> 32) != 0 && uint16(code >> 48) != 0,
            "registration"
        );
        riskCode[pool] = code;
        emit PoolRegistered(pool, code);
    }

    function configure(uint8 count, uint256 riskA, uint256 riskB, uint256 riskC, uint256 riskD, address engine_)
        external
    {
        require(
            msg.sender == administrator && count >= 8 && riskA != 0 && riskB != 0 && riskC != 0 && riskD != 0
                && engine_ != address(0),
            "configuration"
        );
        requiredSettlements = count;
        requiredRiskA = riskA;
        requiredRiskB = riskB;
        requiredRiskC = riskC;
        requiredRiskD = riskD;
        engine = engine_;
        administrator = address(0);
    }

    function record(address owner, uint256 pool) external {
        require(msg.sender == engine && !settled[owner][pool] && settlementCount[owner] < requiredSettlements, "record");
        uint80 code = riskCode[pool];
        require(code != 0, "pool");
        settled[owner][pool] = true;
        ++settlementCount[owner];
        settledRiskA[owner] += uint16(code);
        settledRiskB[owner] += uint16(code >> 16);
        settledRiskC[owner] += uint16(code >> 32);
        settledRiskD[owner] += uint16(code >> 48);
    }

    function cleared(address owner) external view returns (bool) {
        return settlementCount[owner] == requiredSettlements && settledRiskA[owner] == requiredRiskA
            && settledRiskB[owner] == requiredRiskB && settledRiskC[owner] == requiredRiskC
            && settledRiskD[owner] == requiredRiskD;
    }
}
