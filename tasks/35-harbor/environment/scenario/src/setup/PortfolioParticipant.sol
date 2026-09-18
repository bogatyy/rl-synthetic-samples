// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenActor {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
interface IComponentActor is ITokenActor { function deposit(uint256, address) external returns (uint256); }
interface IIndexActor is ITokenActor { function mint(uint256) external; }
interface IPoolActor { function supply(address, uint256, address, uint16) external; }

contract PortfolioParticipant {
    address public immutable settlement;
    address public immutable index;
    address public immutable pool;
    address[5] private components;
    bytes32 public immutable participantTag;

    constructor(address settlement_, address index_, address pool_, address[5] memory components_, bytes32 tag_) {
        settlement = settlement_;
        index = index_;
        pool = pool_;
        components = components_;
        participantTag = tag_;
        ITokenActor(settlement_).approve(components_[0], type(uint256).max);
        ITokenActor(settlement_).approve(components_[1], type(uint256).max);
        ITokenActor(settlement_).approve(components_[2], type(uint256).max);
        ITokenActor(settlement_).approve(components_[3], type(uint256).max);
        ITokenActor(settlement_).approve(components_[4], type(uint256).max);
        for (uint256 i; i < 5; ++i) ITokenActor(components_[i]).approve(index_, type(uint256).max);
        ITokenActor(index_).approve(pool_, type(uint256).max);
    }

    function enter(uint256 indexShares) external {
        require(indexShares % 5 == 0, "weights");
        uint256 componentAssets = indexShares / 5 / 1e12;
        for (uint256 i; i < 5; ++i) IComponentActor(components[i]).deposit(componentAssets, address(this));
        IIndexActor(index).mint(indexShares);
        IPoolActor(pool).supply(index, indexShares, address(this), uint16(uint256(participantTag)));
    }
}

contract GovernanceTimelock {
    address public immutable protocol;
    uint64 public immutable delay;
    bytes32 public immutable configurationCommitment;
    constructor(address protocol_, uint64 delay_, bytes32 commitment_) payable { protocol = protocol_; delay = delay_; configurationCommitment = commitment_; }
}
