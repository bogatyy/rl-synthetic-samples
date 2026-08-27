// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IRivenPool {
    function assetAt(uint256 index) external view returns (address);
    function quoteExactOutput(uint256[3] memory balances, uint8 indexIn, uint8 indexOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);
}

contract RivenBatchVault {
    struct BatchStep {
        bytes32 poolId;
        uint8 assetInIndex;
        uint8 assetOutIndex;
        uint128 amountOut;
        bytes userData;
    }

    struct PoolRecord {
        address pool;
        uint64 lastChangeBlock;
        bool registered;
        uint256[3] balances;
    }

    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public liquidityProvider;
    bytes32[] private poolIds;
    mapping(bytes32 => PoolRecord) private records;
    mapping(address => mapping(address => uint256)) public internalBalance;

    event PoolRegistered(bytes32 indexed poolId, address indexed pool, address[3] assets);
    event Swap(
        bytes32 indexed poolId,
        address indexed caller,
        uint8 indexed assetIn,
        uint8 assetOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event InternalBalanceChanged(address indexed account, address indexed asset, int256 delta);

    function registerPool(address pool, uint256[3] calldata initialBalances) external returns (bytes32 poolId) {
        require(msg.sender == administrator && pool != address(0), "administrator");
        poolId = keccak256(abi.encode(pool, poolIds.length, block.chainid));
        require(!records[poolId].registered, "pool");
        address[3] memory assets;
        for (uint256 i; i < 3; ++i) {
            assets[i] = IRivenPool(pool).assetAt(i);
            require(assets[i] != address(0) && initialBalances[i] != 0, "asset");
        }
        records[poolId] = PoolRecord(pool, uint64(block.number), true, initialBalances);
        poolIds.push(poolId);
        emit PoolRegistered(poolId, pool, assets);
    }

    function configure(address cash, address lender) external {
        require(msg.sender == administrator && settlementAsset == address(0) && poolIds.length >= 1, "configuration");
        settlementAsset = cash;
        protectedReserve = address(this);
        liquidityProvider = lender;
        administrator = address(0);
    }

    function poolCount() external view returns (uint256) {
        return poolIds.length;
    }

    function poolIdAt(uint256 index) external view returns (bytes32) {
        return poolIds[index];
    }

    function poolState(bytes32 poolId)
        external
        view
        returns (address pool, uint256[3] memory balances, uint64 lastChangeBlock)
    {
        PoolRecord storage record = records[poolId];
        require(record.registered, "pool");
        return (record.pool, record.balances, record.lastChangeBlock);
    }

    function poolAssets(bytes32 poolId) public view returns (address[] memory assets) {
        PoolRecord storage record = records[poolId];
        require(record.registered, "pool");
        assets = new address[](3);
        for (uint256 i; i < 3; ++i) {
            assets[i] = IRivenPool(record.pool).assetAt(i);
        }
    }

    function batchSwap(BatchStep[] calldata steps, address[] calldata assets, int256[] calldata limits)
        external
        returns (int256[] memory deltas)
    {
        require(steps.length >= 4 && steps.length <= 700 && assets.length == 3 && limits.length == 3, "batch");
        bytes32 poolId = steps[0].poolId;
        PoolRecord storage record = records[poolId];
        require(record.registered, "pool");
        for (uint256 i; i < 3; ++i) {
            require(assets[i] == IRivenPool(record.pool).assetAt(i), "assets");
        }

        uint256[3] memory working = record.balances;
        deltas = new int256[](3);
        for (uint256 i; i < steps.length; ++i) {
            BatchStep calldata step = steps[i];
            require(step.poolId == poolId && step.userData.length <= 32, "step pool");
            require(
                step.assetInIndex < 3 && step.assetOutIndex < 3 && step.assetInIndex != step.assetOutIndex, "indices"
            );
            uint256 amountOut = step.amountOut;
            require(amountOut != 0 && amountOut < working[step.assetOutIndex], "output");
            uint256 amountIn =
                IRivenPool(record.pool).quoteExactOutput(working, step.assetInIndex, step.assetOutIndex, amountOut);
            working[step.assetInIndex] += amountIn;
            working[step.assetOutIndex] -= amountOut;
            deltas[step.assetInIndex] += int256(amountIn);
            deltas[step.assetOutIndex] -= int256(amountOut);
            emit Swap(poolId, msg.sender, step.assetInIndex, step.assetOutIndex, amountIn, amountOut);
        }

        for (uint256 i; i < 3; ++i) {
            require(deltas[i] <= limits[i], "limit");
            if (deltas[i] > 0) {
                require(IERC20Like(assets[i]).transferFrom(msg.sender, address(this), uint256(deltas[i])), "input");
            } else if (deltas[i] < 0) {
                uint256 credit = uint256(-deltas[i]);
                internalBalance[msg.sender][assets[i]] += credit;
                emit InternalBalanceChanged(msg.sender, assets[i], int256(credit));
            }
            record.balances[i] = working[i];
        }
        record.lastChangeBlock = uint64(block.number);
    }

    function withdrawInternal(address[] calldata assets, uint256[] calldata amounts, address receiver) external {
        require(assets.length == amounts.length && receiver != address(0), "withdrawal");
        for (uint256 i; i < assets.length; ++i) {
            uint256 amount = amounts[i] == 0 ? internalBalance[msg.sender][assets[i]] : amounts[i];
            internalBalance[msg.sender][assets[i]] -= amount;
            require(IERC20Like(assets[i]).transfer(receiver, amount), "transfer");
            emit InternalBalanceChanged(msg.sender, assets[i], -int256(amount));
        }
    }
}
