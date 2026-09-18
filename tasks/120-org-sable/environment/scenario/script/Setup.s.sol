// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {CrocSwapDex} from "../src/ambient/CrocSwapDex.sol";
import {HotProxy} from "../src/ambient/callpaths/HotPath.sol";
import {WarmPath} from "../src/ambient/callpaths/WarmPath.sol";
import {ColdPath} from "../src/ambient/callpaths/ColdPath.sol";
import {LongPath} from "../src/ambient/callpaths/LongPath.sol";
import {MicroPaths} from "../src/ambient/callpaths/MicroPaths.sol";
import {KnockoutFlagPath, KnockoutLiqPath} from "../src/ambient/callpaths/KnockoutPath.sol";
import {SafeModePath} from "../src/ambient/callpaths/SafeModePath.sol";
import {TickMath} from "../src/ambient/libraries/TickMath.sol";
import {
    FixtureToken,
    FixtureWrappedNative,
    FixtureFlashVault,
    FixtureStateBuilder,
    FixtureAuthority,
    IFixtureERC20
} from "../src/FixtureContracts.sol";
import {FixtureCrocQuery} from "../src/FixtureCrocQuery.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

interface ICrocSetup {
    function protocolCmd(uint16 callpath, bytes calldata cmd, bool sudo) external payable;
    function userCmd(uint16 callpath, bytes calldata cmd) external payable returns (bytes memory);
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 private constant POOL_INDEX = 420;
    int24 private constant HISTORICAL_TICK = 202381;
    uint128 private constant HISTORICAL_PRICE = 457_474_964_621_745_751_720_564;
    uint256 private constant MARKET_TOKEN_COUNT = 16;
    uint256 private constant MARKET_POOL_COUNT = 48;

    function run() external {
        vm.startBroadcast(KEY);

        CrocSwapDex dex = new CrocSwapDex();
        _install(dex, address(new HotProxy()), 1);
        _install(dex, address(new WarmPath()), 2);
        _install(dex, address(new ColdPath()), 3);
        _install(dex, address(new LongPath()), 4);
        _install(dex, address(new MicroPaths()), 5);
        _install(dex, address(new KnockoutLiqPath()), 7);
        _install(dex, address(new KnockoutFlagPath()), 3500);
        _install(dex, address(new SafeModePath()), 9999);
        dex.protocolCmd(3, abi.encode(uint8(22), false), true);

        new FixtureCrocQuery(address(dex));
        FixtureToken cash = new FixtureToken("USD Coin", "USDC", 6);
        FixtureWrappedNative wrapped = new FixtureWrappedNative();
        FixtureFlashVault lender = new FixtureFlashVault();
        FixtureStateBuilder stateBuilder = new FixtureStateBuilder(address(dex));

        cash.mint(DEPLOYER, 2_000_000_000e6);
        cash.approve(address(dex), type(uint256).max);
        wrapped.deposit{value: 1_000 ether}();
        wrapped.transfer(address(lender), 500 ether);
        cash.transfer(address(lender), 50_000_000e6);
        cash.transfer(address(stateBuilder), 5_000_000e6);
        (bool funded,) = address(stateBuilder).call{value: 1_200 ether}("");
        require(funded, "state builder funding");
        stateBuilder.approveToken(IFixtureERC20(address(cash)));

        ICrocSetup(address(dex)).protocolCmd(3, abi.encode(uint8(112), uint128(1_000_000)), false);
        ICrocSetup(address(dex)).protocolCmd(
            3,
            abi.encode(uint8(110), POOL_INDEX, uint16(2700), uint16(16), uint8(3), uint8(36), uint8(0)),
            false
        );
        stateBuilder.command(
            3,
            abi.encode(uint8(71), address(0), address(cash), POOL_INDEX, TickMath.getSqrtRatioAtTick(HISTORICAL_TICK)),
            100 ether
        );
        stateBuilder.command(
            2,
            abi.encode(
                uint8(3),
                address(0),
                address(cash),
                POOL_INDEX,
                int24(0),
                int24(0),
                uint128(1_252_175_607_789_945),
                TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK),
                TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK) - 1,
                uint8(0),
                address(0)
            ),
            500 ether
        );
        stateBuilder.command(
            2,
            abi.encode(
                uint8(1),
                address(0),
                address(cash),
                POOL_INDEX,
                int24(190_000),
                int24(202_400),
                uint128(4_708_383_249_762_304),
                TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK),
                TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK) - 1,
                uint8(0),
                address(0)
            ),
            500 ether
        );

        _seasonTarget(dex, cash);
        _seedSurroundingMarkets(dex, stateBuilder);

        _finalizeState(dex, cash, wrapped, stateBuilder);
        vm.stopBroadcast();
    }

    function _finalizeState(
        CrocSwapDex dex,
        FixtureToken cash,
        FixtureWrappedNative wrapped,
        FixtureStateBuilder stateBuilder
    ) private {
        stateBuilder.drainToken(IFixtureERC20(address(cash)), DEPLOYER);
        stateBuilder.drainNative(payable(DEPLOYER));
        stateBuilder.renounceAdministration();

        FixtureAuthority authority = new FixtureAuthority();
        dex.protocolCmd(3, abi.encode(uint8(20), address(authority)), true);
        cash.transfer(address(authority), cash.balanceOf(DEPLOYER));
        wrapped.transfer(address(authority), wrapped.balanceOf(DEPLOYER));
        cash.renounceAdministration();
        (bool locked,) = address(authority).call{value: DEPLOYER.balance - 100 ether}("");
        require(locked, "native lock");
    }

    function _seasonTarget(CrocSwapDex dex, FixtureToken cash) private {
        for (uint256 i; i < 16; ++i) {
            ICrocSetup(address(dex)).userCmd{value: 1 ether}(
                1,
                abi.encode(
                    address(0),
                    address(cash),
                    POOL_INDEX,
                    true,
                    true,
                    uint128(1 ether),
                    uint16(0),
                    TickMath.getSqrtRatioAtTick(HISTORICAL_TICK + 15),
                    uint128(0),
                    uint8(0)
                )
            );
            ICrocSetup(address(dex)).userCmd(
                1,
                abi.encode(
                    address(0),
                    address(cash),
                    POOL_INDEX,
                    false,
                    false,
                    uint128(10_000e6),
                    uint16(0),
                    TickMath.getSqrtRatioAtTick(HISTORICAL_TICK),
                    uint128(0),
                    uint8(0)
                )
            );
        }
        ICrocSetup(address(dex)).userCmd{value: 1 ether}(
            1,
            abi.encode(
                address(0),
                address(cash),
                POOL_INDEX,
                true,
                true,
                uint128(1 ether),
                uint16(0),
                HISTORICAL_PRICE,
                uint128(0),
                uint8(0)
            )
        );
    }

    function _seedSurroundingMarkets(CrocSwapDex dex, FixtureStateBuilder stateBuilder) private {
        _setTemplate(dex, 421, 500, 8, 0);
        _setTemplate(dex, 422, 3_000, 16, 2);
        _setTemplate(dex, 423, 10_000, 32, 6);

        FixtureToken[] memory assets = new FixtureToken[](MARKET_TOKEN_COUNT);
        for (uint256 i; i < MARKET_TOKEN_COUNT; ++i) {
            assets[i] = new FixtureToken("Market Asset", "MKT", 18);
            assets[i].mint(address(stateBuilder), 1e30);
            stateBuilder.approveToken(IFixtureERC20(address(assets[i])));
        }

        for (uint256 ordinal; ordinal < MARKET_POOL_COUNT; ++ordinal) {
            _seedMarket(stateBuilder, assets, ordinal);
        }

        for (uint256 i; i < MARKET_TOKEN_COUNT; ++i) {
            stateBuilder.drainToken(
                IFixtureERC20(address(assets[i])), address(0x000000000000000000000000000000000000dEaD)
            );
            assets[i].renounceAdministration();
        }
    }

    function _seedMarket(FixtureStateBuilder stateBuilder, FixtureToken[] memory assets, uint256 ordinal) private {
        uint256 group = ordinal / MARKET_TOKEN_COUNT;
        uint256 left = ordinal % MARKET_TOKEN_COUNT;
        uint256 right = (left + 1 + group * 2) % MARKET_TOKEN_COUNT;
        (address base, address quote) = _ordered(address(assets[left]), address(assets[right]));
        uint256 pool = 421 + group;
        uint16 grid = group == 0 ? 8 : group == 1 ? 16 : 32;
        uint256 entropy = uint256(keccak256(abi.encode("ambient-local-market", ordinal)));
        int24 center = int24(int256(entropy % 2001) - 1000) * int24(uint24(grid));

        stateBuilder.command(
            3, abi.encode(uint8(71), base, quote, pool, TickMath.getSqrtRatioAtTick(center)), 0
        );
        _warm(stateBuilder, 3, base, quote, pool, 0, 0, uint128(5e20 + (entropy % 500) * 1e18));

        int24 step = int24(uint24(grid));
        _warm(
            stateBuilder,
            1,
            base,
            quote,
            pool,
            center - 12 * step,
            center + 12 * step,
            _lots(uint128(8e19 + ((entropy >> 16) % 200) * 1e18))
        );
        _warm(
            stateBuilder,
            1,
            base,
            quote,
            pool,
            center - 96 * step,
            center + 96 * step,
            _lots(uint128(2e20 + ((entropy >> 32) % 500) * 1e18))
        );

        int24 span = int24(int256(16 + ((entropy >> 48) % 48))) * step;
        for (uint256 round; round < 2; ++round) {
            _swap(stateBuilder, base, quote, pool, true, true, center + span);
            _swap(stateBuilder, base, quote, pool, false, false, center - span);
            _swap(stateBuilder, base, quote, pool, true, true, center);
        }
    }

    function _setTemplate(CrocSwapDex dex, uint256 pool, uint16 fee, uint16 grid, uint8 jit) private {
        ICrocSetup(address(dex)).protocolCmd(
            3, abi.encode(uint8(110), pool, fee, grid, jit, uint8(36), uint8(0)), false
        );
    }

    function _warm(
        FixtureStateBuilder stateBuilder,
        uint8 code,
        address base,
        address quote,
        uint256 pool,
        int24 bid,
        int24 ask,
        uint128 liquidity
    ) private {
        stateBuilder.command(
            2,
            abi.encode(
                code,
                base,
                quote,
                pool,
                bid,
                ask,
                liquidity,
                TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK),
                TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK) - 1,
                uint8(0),
                address(0)
            ),
            0
        );
    }

    function _swap(
        FixtureStateBuilder stateBuilder,
        address base,
        address quote,
        uint256 pool,
        bool buy,
        bool inBase,
        int24 limitTick
    ) private {
        stateBuilder.command(
            1,
            abi.encode(
                base,
                quote,
                pool,
                buy,
                inBase,
                uint128(1e28),
                uint16(0),
                TickMath.getSqrtRatioAtTick(limitTick),
                uint128(0),
                uint8(0)
            ),
            0
        );
    }

    function _ordered(address left, address right) private pure returns (address base, address quote) {
        return left < right ? (left, right) : (right, left);
    }

    function _lots(uint128 liquidity) private pure returns (uint128) {
        return liquidity >> 11 << 11;
    }

    function _install(CrocSwapDex dex, address sidecar, uint16 slot) private {
        dex.protocolCmd(0, abi.encode(uint8(21), sidecar, slot), true);
    }
}
