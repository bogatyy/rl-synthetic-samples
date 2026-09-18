// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "./production/nexus_dip.sol";

interface ILockToken {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract FixedSupplyToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply_) ERC20(name_, symbol_) {
        _mint(msg.sender, supply_);
    }
}

contract WrappedNative {
    string public constant name = "Wrapped BNB";
    string public constant symbol = "WBNB";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    receive() external payable { deposit(); }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposit(msg.sender, msg.value);
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 value) external {
        balanceOf[msg.sender] -= value;
        totalSupply -= value;
        emit Withdrawal(msg.sender, value);
        emit Transfer(msg.sender, address(0), value);
        (bool success,) = msg.sender.call{value: value}("");
        require(success, "WBNB: native transfer failed");
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

/// @dev The historical fee recipient is a contract. Its unrelated application
/// logic is not involved when DIP transfers ERC20 fees to it.
contract FeeSink {}

/// @dev Holds the protocol inventory and residual LP positions under a live
/// owner, mirroring the separate inventory custodian in the production state.
contract ProtocolDistributor {
    address public immutable owner = msg.sender;

    function distribute(address token, address recipient, uint256 amount) external {
        require(msg.sender == owner, "Distributor: not owner");
        require(recipient != address(0), "Distributor: zero recipient");
        require(ILockToken(token).transfer(recipient, amount), "Distributor: transfer failed");
    }
}

/// @notice Local reconstruction of the relevant PinkLock custody surface.
/// Locks are persistent, enumerable by token, transferable by their owner, and
/// withdrawable only by that owner after the configured unlock time.
contract PinkLock {
    struct TokenLock {
        uint256 id;
        address token;
        address owner;
        uint256 amount;
        uint256 lockDate;
        uint256 unlockDate;
        uint256 unlockedAmount;
        string description;
    }

    uint256 public nextLockId = 1_500_000;
    mapping(uint256 => TokenLock) private locks;
    mapping(address => uint256[]) private lockIdsByToken;

    event LockAdded(uint256 indexed id, address indexed token, address indexed owner, uint256 amount, uint256 unlockDate);
    event LockOwnerChanged(uint256 indexed id, address indexed oldOwner, address indexed newOwner);
    event LockWithdrawn(uint256 indexed id, address indexed owner, uint256 amount);

    function lockLPToken(
        address owner,
        address token,
        bool,
        uint256 amount,
        uint256 unlockDate,
        string calldata description
    ) external returns (uint256 id) {
        require(owner != address(0) && amount != 0 && unlockDate > block.timestamp, "PinkLock: invalid lock");
        require(ILockToken(token).transferFrom(msg.sender, address(this), amount), "PinkLock: transfer failed");
        id = nextLockId++;
        locks[id] = TokenLock(id, token, owner, amount, block.timestamp, unlockDate, 0, description);
        lockIdsByToken[token].push(id);
        emit LockAdded(id, token, owner, amount, unlockDate);
    }

    function getLockById(uint256 id) external view returns (TokenLock memory) { return locks[id]; }

    function getLocksForToken(address token, uint256 start, uint256 end)
        external view returns (TokenLock[] memory result)
    {
        uint256[] storage ids = lockIdsByToken[token];
        if (end > ids.length) end = ids.length;
        if (start > end) start = end;
        result = new TokenLock[](end - start);
        for (uint256 i = start; i < end; ++i) result[i - start] = locks[ids[i]];
    }

    function getNumLocksForToken(address token) external view returns (uint256) {
        return lockIdsByToken[token].length;
    }

    function transferLockOwnership(uint256 id, address newOwner) external {
        TokenLock storage item = locks[id];
        require(msg.sender == item.owner && newOwner != address(0), "PinkLock: not lock owner");
        address oldOwner = item.owner;
        item.owner = newOwner;
        emit LockOwnerChanged(id, oldOwner, newOwner);
    }

    function unlock(uint256 id) external {
        TokenLock storage item = locks[id];
        require(msg.sender == item.owner, "PinkLock: not lock owner");
        require(block.timestamp >= item.unlockDate, "PinkLock: still locked");
        uint256 amount = item.amount - item.unlockedAmount;
        require(amount != 0, "PinkLock: empty");
        item.unlockedAmount = item.amount;
        require(ILockToken(item.token).transfer(item.owner, amount), "PinkLock: transfer failed");
        emit LockWithdrawn(id, item.owner, amount);
    }
}
