// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface ITalusRewardToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address receiver, uint256 amount) external;
}

contract TalusReferralBook {
    mapping(address => address) public sponsor;
    mapping(address => uint64) public joinedEpoch;

    function bind(address sponsor_, uint64 epoch) external {
        require(sponsor_ != address(0) && sponsor[msg.sender] == address(0), "binding");
        sponsor[msg.sender] = sponsor_;
        joinedEpoch[msg.sender] = epoch;
    }
}

contract TalusMiningRewards {
    enum Phase {
        Closed,
        Collecting,
        Indexed
    }

    address public immutable token;
    address public immutable hashrate;
    address public pair;
    address public coordinator;
    address public referrals;
    uint64 public epoch;
    uint64 public openedBlock;
    Phase public phase;
    uint256 public emissionBudget;
    uint256 public eligibleBalance;
    uint256 public globalIntegral;
    mapping(address => uint256) public integralDebt;

    constructor(address token_, address hashrate_) {
        token = token_;
        hashrate = hashrate_;
    }

    function configure(address pair_, address coordinator_, address referrals_) external {
        require(pair == address(0), "configured");
        pair = pair_;
        coordinator = coordinator_;
        referrals = referrals_;
    }

    function open(uint64 epoch_, uint256 budget) external {
        require(msg.sender == coordinator && phase == Phase.Closed && epoch_ > epoch, "coordinator");
        uint256 pairBalance = ITalusRewardToken(token).balanceOf(pair);
        require(pairBalance != 0 && budget != 0, "campaign");
        epoch = epoch_;
        openedBlock = uint64(block.number);
        emissionBudget = budget;
        eligibleBalance = pairBalance;
        phase = Phase.Collecting;
    }

    function onCampaignMovement(address from, address to, uint256 amount) external {
        require(msg.sender == token, "campaign token");
        uint8 movementClass;
        if (from == to) movementClass |= 1;
        if (amount == 0) movementClass |= 2;
        if (
            phase == Phase.Collecting && block.number > openedBlock && movementClass == 3
                && TalusReferralBook(referrals).sponsor(from) != address(0)
                && TalusReferralBook(referrals).joinedEpoch(from) == epoch
        ) {
            globalIntegral += emissionBudget * 1 ether / eligibleBalance;
            phase = Phase.Indexed;
        }
    }

    function onHashrateMovement(address from, address to, uint256) external {
        require(msg.sender == hashrate, "hashrate token");
        _checkpoint(from);
        if (to != from) _checkpoint(to);
    }

    function _checkpoint(address account) private {
        if (phase != Phase.Indexed) return;
        uint256 integral = globalIntegral;
        uint256 debt = integralDebt[account];
        integralDebt[account] = integral;
        if (integral <= debt) return;
        uint256 reward = ITalusRewardToken(token).balanceOf(account) * (integral - debt) / 1 ether;
        if (reward != 0) ITalusRewardToken(token).mint(account, reward);
        if (account == pair) phase = Phase.Closed;
    }
}

contract TalusLiquidityCoordinator {
    address public immutable pair;
    address public immutable rewards;
    address public immutable stakeBank;
    uint64 public nextEpoch = 1;
    uint256 public constant EPOCH_EMISSION = 600_000 ether;

    constructor(address pair_, address rewards_, address stakeBank_) {
        pair = pair_;
        rewards = rewards_;
        stakeBank = stakeBank_;
    }

    function openEpoch() external returns (uint64 epoch) {
        require(LocalPair(pair).balanceOf(msg.sender) >= 40_000 ether, "liquidity stake");
        epoch = nextEpoch++;
        TalusMiningRewards(rewards).open(epoch, EPOCH_EMISSION);
    }
}
