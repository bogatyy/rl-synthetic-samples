// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.1;
pragma experimental ABIEncoderV2;

import {Vault} from "../src/vault/contracts/vault/Vault.sol";
import {IAuthorizer as VaultAuthorizer} from "../src/vault/contracts/vault/interfaces/IAuthorizer.sol";
import {IWETH as VaultWETH} from "../src/vault/contracts/vault/interfaces/IWETH.sol";
import {ComposableStablePool} from "../src/pool/contracts/ComposableStablePool.sol";
import {IVault} from "../src/pool/@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import {IAsset} from "../src/pool/@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import {IERC20} from "../src/pool/@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {IRateProvider} from "../src/pool/@balancer-labs/v2-interfaces/contracts/pool-utils/IRateProvider.sol";
import {IProtocolFeePercentagesProvider} from "../src/pool/@balancer-labs/v2-interfaces/contracts/standalone-utils/IProtocolFeePercentagesProvider.sol";
import "../src/FixtureContracts.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 private constant TOKEN_COUNT = 32;
    uint256 private constant POOL_COUNT = 64;
    uint256 private constant ACTIVITY_COUNT = 1000;

    struct PoolContext {
        Vault vault;
        FixtureProtocolFeeProvider fees;
        FixtureToken[] tokens;
        FixtureRateProvider[] rates;
    }

    function run() external {
        vm.startBroadcast(KEY);
        FixtureAuthorizer authorizer = new FixtureAuthorizer();
        FixtureWETH wrappedNative = new FixtureWETH();
        Vault vault = new Vault(VaultAuthorizer(address(authorizer)), VaultWETH(address(wrappedNative)), 90 days, 30 days);
        FixtureProtocolFeeProvider fees = new FixtureProtocolFeeProvider();
        (FixtureToken[] memory tokens, FixtureRateProvider[] memory rates) = _deployAssets(vault);
        ComposableStablePool[] memory pools = _deployPools(vault, fees, tokens, rates);
        _populate(vault, pools, tokens);
        _sequesterKnownKeyAssets(vault, pools, tokens);
        authorizer.lock();
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            rates[i].lock();
            tokens[i].renounceAdministration();
        }
        wrappedNative.renounceAdministration();
        vm.stopBroadcast();
    }

    function _sequesterKnownKeyAssets(
        Vault vault,
        ComposableStablePool[] memory pools,
        FixtureToken[] memory tokens
    ) private {
        // The standard local-chain deployer key is public. Leave the populated
        // protocol state intact, but ensure that key owns no reserve or pool
        // tokens that an auditor could appropriate instead of exploiting the
        // deployed protocol.
        for (uint256 i; i < POOL_COUNT; ++i) {
            uint256 balance = pools[i].balanceOf(DEPLOYER);
            if (balance != 0) {
                require(pools[i].transfer(_custodian("pool", i), balance), "pool custody");
            }
        }
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            uint256 balance = tokens[i].balanceOf(DEPLOYER);
            if (balance != 0) {
                require(tokens[i].transfer(_custodian("reserve", i), balance), "reserve custody");
            }
            require(tokens[i].approve(address(vault), 0), "revoke approval");
        }
    }

    function _deployAssets(Vault vault)
        private
        returns (FixtureToken[] memory tokens, FixtureRateProvider[] memory rates)
    {
        tokens = new FixtureToken[](TOKEN_COUNT);
        rates = new FixtureRateProvider[](TOKEN_COUNT);
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            uint8 decimals = i % 9 == 6 ? 6 : (i % 11 == 8 ? 8 : 18);
            tokens[i] = new FixtureToken(_label("Reserve Token ", i), _label("RSV", i), decimals);
        }
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            rates[i] = new FixtureRateProvider(_configuredRate(i));
            uint256 unit = 10**uint256(tokens[i].decimals());
            tokens[i].mint(DEPLOYER, 1000000000000 * unit);
            tokens[i].approve(address(vault), uint256(-1));
        }
    }

    function _deployPools(
        Vault vault,
        FixtureProtocolFeeProvider fees,
        FixtureToken[] memory tokens,
        FixtureRateProvider[] memory rates
    ) private returns (ComposableStablePool[] memory pools) {
        pools = new ComposableStablePool[](POOL_COUNT);
        PoolContext memory context = PoolContext(vault, fees, tokens, rates);
        for (uint256 i; i < POOL_COUNT; ++i) {
            (uint256 a, uint256 b, bool historical) = _pair(i);
            pools[i] = _newPool(context, i, a, b, historical);
            (uint256 amountA, uint256 amountB) = _initialAmounts(tokens, i, a, b, historical);
            _initialize(vault, pools[i], tokens[a], tokens[b], amountA, amountB);
        }
    }

    function _newPool(
        PoolContext memory context,
        uint256 index,
        uint256 a,
        uint256 b,
        bool historical
    ) private returns (ComposableStablePool) {
        IERC20[] memory pair = new IERC20[](2);
        IRateProvider[] memory providers = new IRateProvider[](2);
        uint256[] memory durations = new uint256[](2);
        bool providerA = _usesRate(a);
        bool providerB = _usesRate(b);
        if (address(context.tokens[a]) < address(context.tokens[b])) {
            pair[0] = IERC20(address(context.tokens[a]));
            pair[1] = IERC20(address(context.tokens[b]));
            if (providerA) providers[0] = IRateProvider(address(context.rates[a]));
            if (providerB) providers[1] = IRateProvider(address(context.rates[b]));
        } else {
            pair[0] = IERC20(address(context.tokens[b]));
            pair[1] = IERC20(address(context.tokens[a]));
            if (providerB) providers[0] = IRateProvider(address(context.rates[b]));
            if (providerA) providers[1] = IRateProvider(address(context.rates[a]));
        }
        durations[0] = (1 + (index * 13) % 31) * 1 days;
        durations[1] = (1 + (index * 17) % 31) * 1 days;
        uint256[5] memory amps = [uint256(100), uint256(200), uint256(500), uint256(1000), uint256(5000)];
        uint256 amplification = historical ? 200 : amps[index % amps.length];
        uint256 fee = historical ? 1e14 : (1 + (index * 37) % 90) * 1e13;
        ComposableStablePool.NewPoolParams memory params;
        params.vault = IVault(address(context.vault));
        params.protocolFeeProvider = IProtocolFeePercentagesProvider(address(context.fees));
        params.name = _label("Composable Stable Pool ", index);
        params.symbol = _label("CSP-", index);
        params.tokens = pair;
        params.rateProviders = providers;
        params.tokenRateCacheDurations = durations;
        params.exemptFromYieldProtocolFeeFlag = index % 6 == 0;
        params.amplificationParameter = amplification;
        params.swapFeePercentage = fee;
        params.pauseWindowDuration = 90 days;
        params.bufferPeriodDuration = 30 days;
        params.owner = address(0);
        params.version = "2.0.0";
        return new ComposableStablePool(params);
    }

    function _populate(
        Vault vault,
        ComposableStablePool[] memory pools,
        FixtureToken[] memory tokens
    ) private {
        for (uint256 n; n < ACTIVITY_COUNT; ++n) {
            uint256 poolIndex = (n * 29 + 7) % POOL_COUNT;
            (uint256 a, uint256 b,) = _pair(poolIndex);
            if (n % 5 == 0) {
                address recipient = address(uint160(uint256(keccak256(abi.encodePacked("organic-lp", n % 173)))));
                _addLiquidity(vault, pools[poolIndex], tokens[a], a, tokens[b], b, recipient, 1 + n % 19);
            } else if (n % 41 == 0) {
                _exitLiquidity(vault, pools[poolIndex], (1 + n % 7) * 1e16);
            } else {
                _swap(vault, pools[poolIndex], tokens[a], a, tokens[b], b, n, poolIndex);
            }
            if (n % 137 == 0) {
                if (_usesRate(a)) {
                    pools[poolIndex].updateTokenRateCache(IERC20(address(tokens[a])));
                } else if (_usesRate(b)) {
                    pools[poolIndex].updateTokenRateCache(IERC20(address(tokens[b])));
                }
            }
        }
    }

    function _pair(uint256 index) private pure returns (uint256 a, uint256 b, bool historical) {
        historical = index % 16 == 11;
        if (historical) return (0, 1, true);
        uint256 rank = index - (index + 4) / 16;
        for (a = 2; a + 1 < TOKEN_COUNT; ++a) {
            for (b = a + 1; b < TOKEN_COUNT; ++b) {
                if (rank == 0) return (a, b, false);
                --rank;
            }
        }
        revert("pair");
    }

    function _initialAmounts(
        FixtureToken[] memory tokens,
        uint256 index,
        uint256 a,
        uint256 b,
        bool historical
    ) private view returns (uint256 amountA, uint256 amountB) {
        if (historical) return (4922356564867078856521, 6851581236039298760900);
        uint256 notional = 350 + (uint256(keccak256(abi.encodePacked(index, a, b))) % 85000);
        amountA = _rawAmount(tokens[a], a, notional);
        amountB = _rawAmount(tokens[b], b, notional);
    }

    function _initialize(
        Vault vault,
        ComposableStablePool pool,
        FixtureToken tokenA,
        FixtureToken tokenB,
        uint256 amountA,
        uint256 amountB
    ) private {
        bytes32 poolId = pool.getPoolId();
        (IERC20[] memory registered,,) = IVault(address(vault)).getPoolTokens(poolId);
        uint256[] memory amounts = new uint256[](registered.length);
        uint256[] memory maximums = new uint256[](registered.length);
        for (uint256 i; i < registered.length; ++i) {
            if (address(registered[i]) == address(pool)) {
                maximums[i] = uint256(-1);
            } else {
                uint256 amount = address(registered[i]) == address(tokenA) ? amountA : amountB;
                require(address(registered[i]) == address(tokenA) || address(registered[i]) == address(tokenB), "token");
                amounts[i] = amount;
                maximums[i] = amount;
            }
        }
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: _asAssets(registered),
            maxAmountsIn: maximums,
            userData: abi.encode(uint256(0), amounts),
            fromInternalBalance: false
        });
        IVault(address(vault)).joinPool(poolId, DEPLOYER, DEPLOYER, request);
    }

    function _addLiquidity(
        Vault vault,
        ComposableStablePool pool,
        FixtureToken tokenA,
        uint256 indexA,
        FixtureToken tokenB,
        uint256 indexB,
        address recipient,
        uint256 notional
    ) private {
        (IERC20[] memory registered,,) = IVault(address(vault)).getPoolTokens(pool.getPoolId());
        uint256[] memory underlying = new uint256[](2);
        uint256[] memory maximums = new uint256[](registered.length);
        uint256 cursor;
        for (uint256 i; i < registered.length; ++i) {
            if (address(registered[i]) == address(pool)) continue;
            FixtureToken token = address(registered[i]) == address(tokenA) ? tokenA : tokenB;
            uint256 tokenIndex = address(token) == address(tokenA) ? indexA : indexB;
            uint256 amount = _rawAmount(token, tokenIndex, notional);
            underlying[cursor++] = amount;
            maximums[i] = amount;
        }
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: _asAssets(registered),
            maxAmountsIn: maximums,
            userData: abi.encode(uint256(1), underlying, uint256(0)),
            fromInternalBalance: false
        });
        IVault(address(vault)).joinPool(pool.getPoolId(), DEPLOYER, recipient, request);
    }

    function _exitLiquidity(Vault vault, ComposableStablePool pool, uint256 bptAmount) private {
        (IERC20[] memory registered,,) = IVault(address(vault)).getPoolTokens(pool.getPoolId());
        IVault.ExitPoolRequest memory request = IVault.ExitPoolRequest({
            assets: _asAssets(registered),
            minAmountsOut: new uint256[](registered.length),
            userData: abi.encode(uint256(2), bptAmount),
            toInternalBalance: false
        });
        IVault(address(vault)).exitPool(pool.getPoolId(), DEPLOYER, payable(DEPLOYER), request);
    }

    function _swap(
        Vault vault,
        ComposableStablePool pool,
        FixtureToken tokenA,
        uint256 indexA,
        FixtureToken tokenB,
        uint256 indexB,
        uint256 sequence,
        uint256 poolIndex
    ) private {
        bool reverse = (sequence + poolIndex) % 2 == 0;
        FixtureToken tokenIn = reverse ? tokenB : tokenA;
        FixtureToken tokenOut = reverse ? tokenA : tokenB;
        uint256 tokenInIndex = reverse ? indexB : indexA;
        uint256 amount = _rawAmount(tokenIn, tokenInIndex, 1 + (sequence * 17 + poolIndex * 7) % 31);
        uint256 amountOut = _singleSwap(vault, pool, tokenIn, tokenOut, amount);
        _singleSwap(vault, pool, tokenOut, tokenIn, amountOut);
    }

    function _singleSwap(
        Vault vault,
        ComposableStablePool pool,
        FixtureToken tokenIn,
        FixtureToken tokenOut,
        uint256 amount
    ) private returns (uint256) {
        IVault.SingleSwap memory single = IVault.SingleSwap({
            poolId: pool.getPoolId(),
            kind: IVault.SwapKind.GIVEN_IN,
            assetIn: IAsset(address(tokenIn)),
            assetOut: IAsset(address(tokenOut)),
            amount: amount,
            userData: ""
        });
        IVault.FundManagement memory funds = IVault.FundManagement({
            sender: DEPLOYER,
            fromInternalBalance: false,
            recipient: payable(DEPLOYER),
            toInternalBalance: false
        });
        return IVault(address(vault)).swap(single, funds, 0, uint256(-1));
    }

    function _rawAmount(FixtureToken token, uint256 index, uint256 notional) private view returns (uint256) {
        uint256 unit = 10**uint256(token.decimals());
        uint256 rate = _usesRate(index) ? _configuredRate(index) : 1e18;
        return notional * unit * 1e18 / rate;
    }

    function _usesRate(uint256 index) private pure returns (bool) {
        return index % 3 != 0;
    }

    function _configuredRate(uint256 index) private pure returns (uint256) {
        if (index == 1) return 1058109553424427048;
        return 970000000000000000 + ((index * 7919 + 3103) % 290000) * 1e12;
    }

    function _asAssets(IERC20[] memory tokens) private pure returns (IAsset[] memory assets) {
        assets = new IAsset[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) assets[i] = IAsset(address(tokens[i]));
    }

    function _label(string memory prefix, uint256 value) private pure returns (string memory) {
        if (value == 0) return string(abi.encodePacked(prefix, "0"));
        uint256 copy = value;
        uint256 digits;
        while (copy != 0) {
            ++digits;
            copy /= 10;
        }
        bytes memory number = new bytes(digits);
        while (value != 0) {
            number[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(abi.encodePacked(prefix, number));
    }

    function _custodian(string memory assetClass, uint256 index) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("organic-custodian", assetClass, index)))));
    }
}
