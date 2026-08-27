// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./XenonPolicy.sol";

contract SnapshotBook {
    address public administrator = msg.sender;
    address public vault;
    uint32 public cursor;
    uint32 public immutable terminalEpoch;
    mapping(uint32 => int128) public realizedAssets;

    constructor(uint32 epochs) {
        terminalEpoch = epochs;
        for (uint32 i; i < epochs; ++i) {
            if (i < 57) {
                realizedAssets[i] = int128(int256((95_000 + uint256(i % 11) * 4_500) * 1 ether));
                continue;
            }
            uint256 entropy = uint256(keccak256(abi.encode("Xenon epoch result", i)));
            uint256 magnitude = (35_000 + entropy % 1_565_001) * 1 ether;
            bool loss = (entropy >> 192) % 100 < 46;
            realizedAssets[i] = loss ? -int128(int256(magnitude)) : int128(int256(magnitude));
        }
    }

    function bind(address vault_) external {
        require(msg.sender == administrator && vault == address(0), "configuration");
        vault = vault_;
        administrator = address(0);
    }

    function remaining() external view returns (uint32) {
        return terminalEpoch - cursor;
    }

    function advance(uint32 maximum) external returns (int256 realized, uint32 processed) {
        require(msg.sender == vault, "vault");
        uint32 stop = cursor + maximum;
        if (stop > terminalEpoch) stop = terminalEpoch;
        while (cursor < stop) {
            realized += realizedAssets[cursor];
            unchecked {
                ++cursor;
                ++processed;
            }
        }
    }
}

contract RedemptionPolicy {
    uint16 public constant PORTION_BPS = 8_000;
    uint128 public immutable minimumDust;

    constructor(uint128 minimumDust_) {
        minimumDust = minimumDust_;
    }

    function maximum(uint256 shareBalance) external view returns (uint256) {
        if (shareBalance <= minimumDust) return shareBalance;
        uint256 allowed = shareBalance * PORTION_BPS / 10_000;
        return allowed < minimumDust ? minimumDust : allowed;
    }

    function feeBps(uint32 epoch) external pure returns (uint256) {
        return 9 + uint256(epoch * 17 % 23);
    }
}

contract EpochVault {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public snapshotBook;
    address public redemptionPolicy;
    address public checkpointPolicy;

    uint256 public totalSupply;
    uint256 public accountedAssets;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event EpochsRealized(uint32 count, int256 assets);
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event VaultConfigured(address indexed snapshotBook, address indexed checkpointPolicy, address redemptionPolicy);

    function configure(address cash, address book, address redemption, address checkpoint) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        require(
            cash != address(0) && book != address(0) && redemption != address(0) && checkpoint != address(0), "address"
        );
        settlementAsset = cash;
        protectedReserve = address(this);
        snapshotBook = book;
        redemptionPolicy = redemption;
        checkpointPolicy = checkpoint;
        emit VaultConfigured(book, checkpoint, redemption);
    }

    function bootstrap(address receiver, uint256 shares, uint256 assets) external {
        require(msg.sender == administrator && totalSupply == 0, "bootstrap");
        require(receiver != address(0) && shares != 0 && assets != 0, "values");
        totalSupply = shares;
        accountedAssets = assets;
        balanceOf[receiver] = shares;
        administrator = address(0);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address receiver, uint256 shares) external returns (bool) {
        _transfer(msg.sender, receiver, shares);
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 shares) external returns (bool) {
        uint256 permitted = allowance[owner][msg.sender];
        if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - shares;
        _transfer(owner, receiver, shares);
        return true;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * accountedAssets / totalSupply;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return assets * totalSupply / accountedAssets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint32 remainingEpochs = SnapshotBook(snapshotBook).remaining();
        _realize(CheckpointPolicy(checkpointPolicy).depositBudget(remainingEpochs));
        uint256 feeBps = CheckpointPolicy(checkpointPolicy).entryFeeBps(SnapshotBook(snapshotBook).cursor());
        uint256 credited = assets * (10_000 - feeBps) / 10_000;
        shares = credited * totalSupply / accountedAssets;
        require(shares != 0, "shares");
        require(IERC20Like(settlementAsset).transferFrom(msg.sender, address(this), assets), "transfer");
        totalSupply += shares;
        accountedAssets += assets;
        balanceOf[receiver] += shares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function compute() external returns (int256 realized) {
        realized = _realize(1);
    }

    function withdraw(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares != 0 && shares <= balanceOf[msg.sender], "shares");
        require(shares <= RedemptionPolicy(redemptionPolicy).maximum(balanceOf[msg.sender]), "policy");
        uint256 gross = shares * accountedAssets / totalSupply;
        uint256 feeBps = RedemptionPolicy(redemptionPolicy).feeBps(SnapshotBook(snapshotBook).cursor());
        assets = gross * (10_000 - feeBps) / 10_000;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        accountedAssets -= assets;
        require(IERC20Like(settlementAsset).transfer(receiver, assets), "transfer");
        emit Withdraw(msg.sender, receiver, assets, shares);
    }

    function _realize(uint32 maximum) private returns (int256 assets) {
        uint32 count;
        (assets, count) = SnapshotBook(snapshotBook).advance(maximum);
        if (assets > 0) accountedAssets += uint256(assets);
        else if (assets < 0) accountedAssets -= uint256(-assets);
        emit EpochsRealized(count, assets);
    }

    function _transfer(address owner, address receiver, uint256 shares) private {
        require(receiver != address(0), "receiver");
        balanceOf[owner] -= shares;
        balanceOf[receiver] += shares;
    }
}
