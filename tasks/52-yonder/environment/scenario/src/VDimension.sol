// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISettlementAsset {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Local reconstruction of the unverified V-Dimension accounting
/// contract. The public API and the interacting token/market behavior are
/// preserved; bookkeeping is split across the same product, member, epoch,
/// package and dividend concepts visible in the deployed runtime.
contract VDimension {
    struct Product {
        address settlementToken;
        uint32 entryMultiplierBps;
        uint32 exitMultiplierBps;
        uint32 rewardWeight;
        uint96 depositCap;
        uint128 deposited;
        bool active;
    }

    struct Member {
        address sponsor;
        uint128 directVolume;
        uint128 teamVolume;
        uint128 rewardDebt;
        uint64 joinedAt;
        uint32 lastEpoch;
        uint16 rank;
        bool frozen;
    }

    struct Epoch {
        uint64 startsAt;
        uint64 endsAt;
        uint96 rewardPool;
        uint96 totalWeight;
        uint32 memberCount;
        bool finalized;
    }

    struct Package {
        uint96 price;
        uint96 dailyReward;
        uint32 durationDays;
        uint16 rankPoints;
        bool enabled;
    }

    string public constant name = "V-Dimension";
    string public constant symbol = "VDS";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    address public administrator = msg.sender;
    ISettlementAsset public immutable settlementAsset;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => Product) public products;
    mapping(address => Member) public members;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => Package) public packages;
    mapping(address => mapping(uint256 => uint256)) public packagePositions;
    mapping(address => uint256) public lifetimeDeposits;
    mapping(address => uint256) public lifetimeRedemptions;
    mapping(address => uint256) public pendingDividends;
    mapping(address => uint256) public claimedDividends;
    mapping(uint256 => address) public memberAt;
    mapping(address => uint256) public memberIndex;

    uint256 public currentEpoch;
    uint256 public memberCount;
    uint256 public totalProductDeposits;
    uint256 public totalProductRedemptions;
    uint256 public dividendAccumulator;
    uint256 public packageRevenue;
    bool public depositsPaused;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ProductConfigured(address indexed product, address indexed settlementToken, uint256 multiplier);
    event Deposited(address indexed account, address indexed product, uint256 assets, uint256 shares);
    event Redeemed(address indexed account, uint256 shares, uint256 assets);
    event MemberJoined(address indexed account, address indexed sponsor, uint256 index);
    event PackagePurchased(address indexed account, uint256 indexed packageId, uint256 quantity);
    event DividendClaimed(address indexed account, uint256 amount);

    modifier onlyAdministrator() {
        require(msg.sender == administrator, "VDS: administrator");
        _;
    }

    constructor(address settlementAsset_) {
        require(settlementAsset_ != address(0), "VDS: settlement asset");
        settlementAsset = ISettlementAsset(settlementAsset_);
        _register(msg.sender, address(0));
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) {
            allowance[from][msg.sender] = permitted - amount;
            emit Approval(from, msg.sender, permitted - amount);
        }
        _move(from, to, amount);
        return true;
    }

    function deposit(address product, uint256 amount) external {
        require(!depositsPaused && amount != 0, "VDS: deposits unavailable");
        Product storage terms = products[product];
        require(terms.active && terms.settlementToken == address(settlementAsset), "VDS: product");
        require(uint256(terms.deposited) + amount <= terms.depositCap, "VDS: product cap");
        require(settlementAsset.transferFrom(msg.sender, address(this), amount), "VDS: asset transfer");

        uint256 shares = amount * terms.entryMultiplierBps / 10_000;
        terms.deposited += uint128(amount);
        totalProductDeposits += amount;
        lifetimeDeposits[msg.sender] += amount;
        _ensureMember(msg.sender);
        _creditNetwork(msg.sender, amount, terms.rewardWeight);
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, product, amount, shares);
    }

    function buyPackage(uint256 packageId, uint256 quantity, address sponsor) external {
        Package memory item = packages[packageId];
        require(item.enabled && quantity != 0, "VDS: package");
        _register(msg.sender, sponsor);
        uint256 cost = uint256(item.price) * quantity;
        require(settlementAsset.transferFrom(msg.sender, address(this), cost), "VDS: package payment");
        packagePositions[msg.sender][packageId] += quantity;
        packageRevenue += cost;
        Member storage member = members[msg.sender];
        member.directVolume += uint128(cost);
        if (member.sponsor != address(0)) members[member.sponsor].teamVolume += uint128(cost);
        pendingDividends[msg.sender] += uint256(item.dailyReward) * quantity;
        emit PackagePurchased(msg.sender, packageId, quantity);
    }

    function join(address sponsor) external { _register(msg.sender, sponsor); }

    function claimDividend() external {
        uint256 amount = pendingDividends[msg.sender];
        require(amount != 0, "VDS: no dividend");
        pendingDividends[msg.sender] = 0;
        claimedDividends[msg.sender] += amount;
        require(settlementAsset.transfer(msg.sender, amount), "VDS: dividend transfer");
        emit DividendClaimed(msg.sender, amount);
    }

    function checkpointMember(address account) external returns (uint256 accrued) {
        Member storage member = members[account];
        require(member.joinedAt != 0 && !member.frozen, "VDS: member");
        uint256 epochId = currentEpoch;
        if (member.lastEpoch < epochId) {
            Epoch memory epoch = epochs[epochId];
            uint256 weight = uint256(member.directVolume) + uint256(member.teamVolume) / 10;
            accrued = epoch.totalWeight == 0 ? 0 : uint256(epoch.rewardPool) * weight / epoch.totalWeight;
            member.rewardDebt += uint128(accrued);
            member.lastEpoch = uint32(epochId);
            pendingDividends[account] += accrued;
        }
    }

    function memberSummary(address account)
        external
        view
        returns (Member memory member, uint256 tokenBalance, uint256 pending, uint256 lifetimeNet)
    {
        member = members[account];
        tokenBalance = balanceOf[account];
        pending = pendingDividends[account];
        lifetimeNet = lifetimeDeposits[account] - lifetimeRedemptions[account];
    }

    function configureProduct(
        address product,
        address token,
        uint32 entryMultiplierBps,
        uint32 exitMultiplierBps,
        uint32 rewardWeight,
        uint96 cap
    ) external onlyAdministrator {
        require(product != address(0) && token != address(0), "VDS: address");
        products[product] = Product({
            settlementToken: token,
            entryMultiplierBps: entryMultiplierBps,
            exitMultiplierBps: exitMultiplierBps,
            rewardWeight: rewardWeight,
            depositCap: cap,
            deposited: 0,
            active: true
        });
        emit ProductConfigured(product, token, entryMultiplierBps);
    }

    function configurePackage(
        uint256 packageId,
        uint96 price,
        uint96 dailyReward,
        uint32 durationDays,
        uint16 rankPoints,
        bool enabled
    ) external onlyAdministrator {
        packages[packageId] = Package(price, dailyReward, durationDays, rankPoints, enabled);
    }

    function configureEpoch(
        uint256 epochId,
        uint64 startsAt,
        uint64 endsAt,
        uint96 rewardPool,
        uint96 totalWeight,
        uint32 participants,
        bool finalized
    ) external onlyAdministrator {
        epochs[epochId] = Epoch(startsAt, endsAt, rewardPool, totalWeight, participants, finalized);
        if (epochId > currentEpoch) currentEpoch = epochId;
    }

    function seedMember(
        address account,
        address sponsor,
        uint128 directVolume,
        uint128 teamVolume,
        uint128 rewardDebt,
        uint32 lastEpoch,
        uint16 rank,
        bool frozen
    ) external onlyAdministrator {
        _register(account, sponsor);
        Member storage member = members[account];
        member.directVolume = directVolume;
        member.teamVolume = teamVolume;
        member.rewardDebt = rewardDebt;
        member.lastEpoch = lastEpoch;
        member.rank = rank;
        member.frozen = frozen;
    }

    function seedPosition(address account, uint256 shares, uint256 pending) external onlyAdministrator {
        _ensureMember(account);
        _mint(account, shares);
        pendingDividends[account] += pending;
    }

    function pauseDeposits(bool paused) external onlyAdministrator { depositsPaused = paused; }

    function renounceAdministration() external onlyAdministrator { administrator = address(0); }

    function _move(address from, address to, uint256 amount) private {
        require(from != address(0) && to != address(0), "VDS: address");
        if (to == address(this)) {
            _redeem(from, amount);
            return;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _redeem(address account, uint256 shares) private {
        Product memory terms = products[address(this)];
        require(terms.active, "VDS: redemption disabled");
        balanceOf[account] -= shares;
        totalSupply -= shares;
        emit Transfer(account, address(0), shares);
        uint256 assets = shares * terms.exitMultiplierBps / 10_000;
        lifetimeRedemptions[account] += assets;
        totalProductRedemptions += assets;
        require(settlementAsset.transfer(account, assets), "VDS: redemption transfer");
        emit Redeemed(account, shares, assets);
    }

    function _mint(address account, uint256 amount) private {
        totalSupply += amount;
        balanceOf[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _register(address account, address sponsor) private {
        if (members[account].joinedAt != 0) return;
        if (sponsor == account) sponsor = address(0);
        members[account].sponsor = sponsor;
        members[account].joinedAt = uint64(block.timestamp);
        memberAt[memberCount] = account;
        memberIndex[account] = memberCount + 1;
        emit MemberJoined(account, sponsor, memberCount);
        memberCount++;
    }

    function _ensureMember(address account) private {
        if (members[account].joinedAt == 0) _register(account, address(0));
    }

    function _creditNetwork(address account, uint256 amount, uint256 weight) private {
        Member storage member = members[account];
        member.directVolume += uint128(amount);
        member.rewardDebt += uint128(amount * weight / 10_000);
        address sponsor = member.sponsor;
        for (uint256 depth; depth < 5 && sponsor != address(0); ++depth) {
            members[sponsor].teamVolume += uint128(amount / (depth + 2));
            sponsor = members[sponsor].sponsor;
        }
        dividendAccumulator += amount * weight / 10_000;
    }
}
