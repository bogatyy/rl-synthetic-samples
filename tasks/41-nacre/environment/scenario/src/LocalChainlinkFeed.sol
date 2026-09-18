// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Local replacement for the BTC/USD Chainlink proxy used by the
/// historical price reader. Reports are written through ordinary calls and
/// retain Chainlink's phase-encoded round identifiers and read ABI.
contract LocalChainlinkFeed {
    struct Report {
        int256 answer;
        uint64 startedAt;
        uint64 updatedAt;
        bool exists;
    }

    address public immutable owner;
    bool public configurationFinished;
    uint16 public phaseId;
    uint256 private latestRoundId;
    mapping(uint80 => Report) private reports;

    constructor(uint16 phaseId_) {
        owner = msg.sender;
        phaseId = phaseId_;
    }

    function transmit(uint80 roundId, int256 answer, uint64 timestamp, bool makeLatest) external {
        require(msg.sender == owner && !configurationFinished, "owner");
        require(roundId != 0 && answer > 0 && timestamp != 0, "report");
        reports[roundId] = Report(answer, timestamp, timestamp, true);
        if (makeLatest) latestRoundId = roundId;
    }

    function finishConfiguration() external {
        require(msg.sender == owner && !configurationFinished, "owner");
        configurationFinished = true;
    }

    function latestRound() external view returns (uint256) {
        return latestRoundId;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Report memory report = reports[roundId];
        require(report.exists, "No data present");
        return (roundId, report.answer, report.startedAt, report.updatedAt, roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        id = uint80(latestRoundId);
        Report memory report = reports[id];
        require(report.exists, "No data present");
        return (id, report.answer, report.startedAt, report.updatedAt, id);
    }
}
