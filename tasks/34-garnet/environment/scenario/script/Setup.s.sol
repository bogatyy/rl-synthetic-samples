// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DIP} from "../src/production/nexus_dip.sol";
import {AIC, NEX} from "../src/production/NexusTokens.sol";
import {PancakeFactory, PancakePair} from "../src/PancakeV2Core.sol";
import {PancakeRouter} from "../src/PancakeV2Router.sol";
import {
    FixedSupplyToken,
    WrappedNative,
    FeeSink,
    ProtocolDistributor,
    PinkLock
} from "../src/ProtocolSupport.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

interface ISetupToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address private constant DAO = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address private constant NODE = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    uint256 private constant TARGET_AIC_INITIAL = 9_722_807_051_886_451_909_805_103;
    uint256 private constant TARGET_DIP_INITIAL = 26_024_892_955_612_014_312_525_606;
    uint256 private constant TARGET_FINAL_Q = 11_421_872_104_805_359_423;

    uint256 private constant FLASH_AIC_INITIAL = 18_393_339_915_630_930_253_802_965;
    uint256 private constant FLASH_NEX_INITIAL = 49_011_387_727_142_278_026_262_155;
    uint256 private constant FLASH_FINAL_Q = 2_894_209_128_180_781_690;

    uint256 private constant EXIT_AIC_INITIAL = 261_667_880_876_202_593_340_723;
    uint256 private constant EXIT_USDC_INITIAL = 90_506_753_132_625_289_133_458;
    uint256 private constant EXIT_FINAL_Q = 4_328_824_045_591_411_358;

    function run() external {
        vm.startBroadcast(KEY);

        // Stable deployment order keeps all public task addresses deterministic.
        PancakeFactory factory = new PancakeFactory(DEPLOYER);
        WrappedNative wrappedNative = new WrappedNative();
        PancakeRouter router = new PancakeRouter(address(factory), address(wrappedNative));
        FeeSink feeSink = new FeeSink();
        ProtocolDistributor distributor = new ProtocolDistributor();
        PinkLock locker = new PinkLock();
        AIC aic = new AIC("AIC", "AIC");
        NEX nex = new NEX(address(router), address(aic));
        DIP target = new DIP(address(router), address(aic));
        FixedSupplyToken usdc = new FixedSupplyToken("USD Coin", "USDC", 1_000_000_000 ether);

        factory.setFeeTo(address(distributor));
        nex.setFeeAddress(DAO, NODE);
        target.setFeeAddress(address(feeSink));

        // The historical reserves arose from years of activity. Reproduce their
        // fee-grown constant products with ordinary swaps, then restore the exact
        // live transfer fees before handing the chain to the agent.
        nex.setFee(0, 0);
        target.setFee(0);

        PancakePair flashPair = PancakePair(nex.uniswapV2PairAid());
        PancakePair targetPair = PancakePair(target.uniswapV2PairAic());
        PancakePair exitPair = PancakePair(factory.createPair(address(aic), address(usdc)));

        require(flashPair.token0() == address(aic), "Setup: flash ordering");
        require(targetPair.token0() == address(aic), "Setup: target ordering");
        require(exitPair.token0() == address(aic), "Setup: exit ordering");

        _seed(flashPair, address(aic), address(nex), FLASH_AIC_INITIAL, FLASH_NEX_INITIAL);
        _grow(flashPair, address(aic), address(nex), 35, FLASH_FINAL_Q);
        _settle(
            flashPair,
            address(aic),
            address(nex),
            19_609_813_792_175_141_340_246_556,
            52_252_836_702_517_396_009_148_093
        );

        _seed(targetPair, address(aic), address(target), TARGET_AIC_INITIAL, TARGET_DIP_INITIAL);
        _grow(targetPair, address(aic), address(target), 17, TARGET_FINAL_Q);
        _settle(
            targetPair,
            address(aic),
            address(target),
            10_037_659_001_700_876_485_423_256,
            26_867_652_484_527_719_810_575_915
        );

        _seed(exitPair, address(aic), address(usdc), EXIT_AIC_INITIAL, EXIT_USDC_INITIAL);
        _grow(exitPair, address(aic), address(usdc), 133, EXIT_FINAL_Q);
        _settle(
            exitPair,
            address(aic),
            address(usdc),
            331_910_514_958_679_396_334_346,
            114_802_561_701_105_336_499_291
        );

        nex.setFee(3, 3);
        target.setFee(6);

        _lockLiquidity(locker, distributor, flashPair, targetPair, exitPair);

        // Reconstruct the live owner, developer, fee-recipient and treasury shape.
        require(target.transfer(address(feeSink), 1_736_732_265_582_907_976_832_814), "Setup: DIP fee sink");
        require(aic.transfer(address(feeSink), 10_000 ether), "Setup: AIC fee sink");
        require(nex.transfer(DAO, 971_704_087_989_649_574_877_589), "Setup: NEX DAO");
        require(nex.transfer(NODE, 22_574_067_989_649_574_877_589), "Setup: NEX node");
        require(aic.transfer(NODE, 13_204_862_045_300_000_000_000_000), "Setup: AIC node");

        _moveRemainder(address(aic), address(distributor));
        _moveRemainder(address(nex), address(distributor));
        _moveRemainder(address(target), address(distributor));
        _moveRemainder(address(usdc), address(distributor));

        // AIC and NEX historically had no owner; DIP retained a live owner.
        aic.renounceOwnership();
        nex.renounceOwnership();

        vm.stopBroadcast();
    }

    function _seed(PancakePair pair, address token0, address token1, uint256 amount0, uint256 amount1)
        private
    {
        require(ISetupToken(token0).transfer(address(pair), amount0), "Setup: seed token0");
        require(ISetupToken(token1).transfer(address(pair), amount1), "Setup: seed token1");
        pair.mint(DEPLOYER);
    }

    function _grow(PancakePair pair, address token0, address token1, uint256 basePairs, uint256 finalQ)
        private
    {
        for (uint256 i; i < basePairs; ++i) {
            uint256 q = ((i % 5) + 1) * 1 ether;
            _swapIn(pair, token0, true, q);
            _swapIn(pair, token1, false, q);
        }
        _swapIn(pair, token0, true, finalQ);
        _swapIn(pair, token1, false, finalQ);
    }

    function _swapIn(PancakePair pair, address input, bool token0In, uint256 multiplier) private {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 reserveIn = token0In ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = token0In ? uint256(reserve1) : uint256(reserve0);
        uint256 amountIn = reserveIn * multiplier / 1 ether;
        uint256 beforeBalance = ISetupToken(input).balanceOf(address(pair));
        require(ISetupToken(input).transfer(address(pair), amountIn), "Setup: swap input");
        uint256 actualIn = ISetupToken(input).balanceOf(address(pair)) - beforeBalance;
        uint256 amountInWithFee = actualIn * 9_975;
        uint256 amountOut = amountInWithFee * reserveOut / (reserveIn * 10_000 + amountInWithFee);
        pair.swap(token0In ? 0 : amountOut, token0In ? amountOut : 0, DEPLOYER, "");
    }

    function _settle(PancakePair pair, address token0, address token1, uint256 expected0, uint256 expected1)
        private
    {
        uint256 balance0 = ISetupToken(token0).balanceOf(address(pair));
        uint256 balance1 = ISetupToken(token1).balanceOf(address(pair));
        require(balance0 <= expected0 && balance1 <= expected1, "Setup: calibration overshot");
        if (balance0 != expected0) {
            require(ISetupToken(token0).transfer(address(pair), expected0 - balance0), "Setup: settle token0");
        }
        if (balance1 != expected1) {
            require(ISetupToken(token1).transfer(address(pair), expected1 - balance1), "Setup: settle token1");
        }
        pair.sync();
    }

    function _lockLiquidity(
        PinkLock locker,
        ProtocolDistributor distributor,
        PancakePair flashPair,
        PancakePair targetPair,
        PancakePair exitPair
    ) private {
        uint256 unlockDate = block.timestamp + 100 * 365 days;

        uint256[7] memory flashLocks = [
            uint256(28_819_990_734_225_825_648_257_130),
            101_663_706_021_698_012_045_958,
            195_264_728_304_863_471_144_091,
            182_812_863_700_820_423_617_208,
            96_532_312_905_024_508_032_279,
            148_223_958_491_439_761_461_221,
            292_619_970_011_387_435_944_295
        ];
        flashPair.approve(address(locker), type(uint256).max);
        for (uint256 i; i < flashLocks.length; ++i) {
            locker.lockLPToken(DEPLOYER, address(flashPair), true, flashLocks[i], unlockDate, "Pancake LP");
        }
        _moveRemainder(address(flashPair), address(distributor));

        targetPair.approve(address(locker), type(uint256).max);
        locker.lockLPToken(
            DEPLOYER,
            address(targetPair),
            true,
            64_311_740_763_254_107_394_035,
            unlockDate,
            "Pancake LP"
        );
        locker.lockLPToken(
            DEPLOYER,
            address(targetPair),
            true,
            15_842_730_778_859_597_224_429_076,
            unlockDate,
            "Pancake LP"
        );
        _moveRemainder(address(targetPair), address(distributor));

        exitPair.approve(address(locker), type(uint256).max);
        locker.lockLPToken(
            DEPLOYER,
            address(exitPair),
            true,
            exitPair.balanceOf(DEPLOYER),
            unlockDate,
            "Pancake LP"
        );
    }

    function _moveRemainder(address token, address recipient) private {
        uint256 amount = ISetupToken(token).balanceOf(DEPLOYER);
        if (amount != 0) require(ISetupToken(token).transfer(recipient, amount), "Setup: remainder");
    }
}
