// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LocalChainlinkFeed} from "../src/LocalChainlinkFeed.sol";
import {
    HistoricalDepositWrapper,
    HistoricalOwnerController,
    HistoricalShareCustodian
} from "../src/HistoricalActors.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function readFile(string calldata path) external view returns (string memory data);
    function parseBytes(string calldata value) external pure returns (bytes memory data);
    function addr(uint256 privateKey) external pure returns (address keyAddr);
}

interface ISetupToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function owner() external view returns (address);
}

interface ISetupVault {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant DEPLOYER_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 private constant USER_KEY =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    address private constant HISTORICAL_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant HISTORICAL_READER = 0x4d942108211E8139F40a456F40d176e2d3F02d5F;
    address private constant HISTORICAL_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address private constant HISTORICAL_MORPHO_OWNER = 0x937Ce2d6c488b361825D2DB5e8A70e26d48afEd5;

    address private constant EXPECTED_CONTROLLER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address private constant EXPECTED_FEED = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address private constant EXPECTED_WBTC = 0xa16E02E87b7454126E5E10d957A927A7F5B5d2be;
    address private constant EXPECTED_READER = 0xB7A5bd0345EF1Cc5E66bf61BdeC17D2461fBd968;
    address private constant EXPECTED_MORPHO = 0xeEBe00Ac0756308ac4AaBfD76c05c4F3088B8883;
    address private constant EXPECTED_TARGET = 0x10C6E9530F1C1AF873a391030a1D9E8ed0630D26;
    address private constant EXPECTED_CUSTODIAN = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
    address private constant EXPECTED_WRAPPER = 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;

    bytes32 private constant TARGET_RUNTIME_HASH =
        0xf240ab4156209d9925b35c32b3bbf95f1870577a617206be4c8105a212db7fa5;
    bytes32 private constant READER_RUNTIME_HASH =
        0x5692b043bf91c6f522a0a73ba6704a1c5636763f3cf892a0e4551a992281aa0e;
    bytes32 private constant WBTC_RUNTIME_HASH =
        0x131ff5c755b710d543ea70fede2eb38e5d15b1456df0ae932ba12e2786f7e5df;
    bytes32 private constant MORPHO_RUNTIME_HASH =
        0x3fc91dbdca83777d54a7ac7bf44d2982ae1f1396f7492a5aab8c385ee0703d57;

    uint256 private constant OWNER_FUNDS = 2_518_339_081;
    uint256 private constant USER_FUNDS = 100_273_680;
    uint256 private constant MORPHO_LIQUIDITY = 100e8;

    HistoricalOwnerController private controller;
    LocalChainlinkFeed private feed;
    HistoricalShareCustodian private custodian;
    HistoricalDepositWrapper private wrapper;
    address private wbtc;
    address private reader;
    address private morpho;
    address private target;

    /// @dev The historical vault enforced fourteen-day expiries. The task's
    /// local launcher invokes these phases at the corresponding timestamps so
    /// every transition is still made through the production contract's
    /// ordinary public entrypoints.
    function deployAndOpenFirstRound() external {
        vm.startBroadcast(DEPLOYER_KEY);
        _deployProtocol();
        _fundActors();
        _firstOwnerDeposit();
        vm.stopBroadcast();

        _userDeposit(50_000_000, 50_000_000);

        vm.startBroadcast(DEPLOYER_KEY);
        _seedEpoch1();
        _assertReaderCurrent(29_654_608_214);
        _openRound(32_000e6, 6_000_000, 750_000_000);
        vm.stopBroadcast();
    }

    function openSecondRound() external {
        _bind();
        vm.startBroadcast(DEPLOYER_KEY);
        _seedEpoch2();
        _assertReaderAt(1_654_848_000, 3_004_819_000_000, 28_962_050_000);
        _openRound(33_000e6, 6_426_000, 756_000_000);
        vm.stopBroadcast();

        _userDeposit(50_273_680, 49_454_320);
    }

    function openThirdRound() external {
        _bind();
        vm.startBroadcast(DEPLOYER_KEY);
        bytes memory ownerDeposit = controller.invoke(
            address(wrapper),
            abi.encodeCall(
                HistoricalDepositWrapper.deposit,
                (wbtc, target, address(custodian), uint256(1_750_735_426))
            )
        );
        require(abi.decode(ownerDeposit, (uint256)) == 1_722_201_983, "owner shares");

        _seedEpoch3();
        _assertReaderAt(1_656_057_600, 2_090_390_400_000, 21_408_290_543);
        _openRound(25_000e6, 21_660_172, 2_548_255_552);
        vm.stopBroadcast();
    }

    function openFourthRound() external {
        _bind();
        vm.startBroadcast(DEPLOYER_KEY);
        _seedEpoch4();
        _assertReaderAt(1_657_267_200, 2_179_565_708_228, 21_812_550_000);
        _openRound(26_000e6, 16_704_452, 2_569_915_723);
        vm.stopBroadcast();
    }

    function openFifthRound() external {
        _bind();
        vm.startBroadcast(DEPLOYER_KEY);
        _seedEpoch5();
        _assertReaderAt(1_658_476_800, 2_312_169_000_000, 23_465_544_422);
        _openRound(29_000e6, 16_813_031, 2_586_620_174);
        vm.stopBroadcast();
    }

    function settleAndLock() external {
        _bind();
        vm.startBroadcast(DEPLOYER_KEY);
        controller.invoke(target, abi.encodeWithSelector(bytes4(0x01183203), uint256(23_192_880_000)));
        bytes memory withdrawn = controller.invoke(
            address(custodian), abi.encodeCall(HistoricalShareCustodian.withdrawAll, (target))
        );
        require(abi.decode(withdrawn, (uint256)) == 2_603_433_204, "historical withdrawal");

        _assertPreExploitState();
        feed.finishConfiguration();
        controller.seal();
        vm.stopBroadcast();
    }

    function _bind() private {
        controller = HistoricalOwnerController(EXPECTED_CONTROLLER);
        feed = LocalChainlinkFeed(EXPECTED_FEED);
        custodian = HistoricalShareCustodian(EXPECTED_CUSTODIAN);
        wrapper = HistoricalDepositWrapper(EXPECTED_WRAPPER);
        wbtc = EXPECTED_WBTC;
        reader = EXPECTED_READER;
        morpho = EXPECTED_MORPHO;
        target = EXPECTED_TARGET;
    }

    function _deployProtocol() private {
        controller = new HistoricalOwnerController(DEPLOYER);
        feed = new LocalChainlinkFeed(5);
        require(address(controller) == EXPECTED_CONTROLLER && address(feed) == EXPECTED_FEED, "root addresses");

        wbtc = controller.deploy(_runtime("runtime/wbtc-creation.hex"));
        reader = controller.deploy(_runtime("runtime/reader-creation.hex"));

        bytes memory morphoCreation = _runtime("runtime/morpho-creation.hex");
        _replaceAddress(morphoCreation, HISTORICAL_MORPHO_OWNER, address(controller), 1);
        morpho = controller.deploy(morphoCreation);

        // Exact Chainlink round read by the historical target constructor.
        _report(20_403, 2_865_654_565_597, 1_653_693_978, true);

        bytes memory targetCreation = _runtime("runtime/target-creation.hex");
        _replaceAddress(targetCreation, HISTORICAL_WBTC, wbtc, 1);
        _replaceAddress(targetCreation, HISTORICAL_READER, reader, 1);
        _replaceAddress(targetCreation, HISTORICAL_FEED, address(feed), 1);
        target = controller.deploy(targetCreation);

        custodian = new HistoricalShareCustodian(address(controller));
        wrapper = new HistoricalDepositWrapper();

        require(wbtc == EXPECTED_WBTC && reader == EXPECTED_READER, "component addresses");
        require(morpho == EXPECTED_MORPHO && target == EXPECTED_TARGET, "protocol addresses");
        require(address(custodian) == EXPECTED_CUSTODIAN, "custodian address");
        require(address(wrapper) == EXPECTED_WRAPPER, "wrapper address");
        require(target.codehash == TARGET_RUNTIME_HASH, "target runtime");
        require(reader.codehash == READER_RUNTIME_HASH, "reader runtime");
        require(wbtc.codehash == WBTC_RUNTIME_HASH, "WBTC runtime");
        require(morpho.codehash == MORPHO_RUNTIME_HASH, "Morpho runtime");
    }

    function _fundActors() private {
        address user = vm.addr(USER_KEY);
        _invokeWbtc(abi.encodeWithSignature("mint(address,uint256)", address(controller), OWNER_FUNDS));
        _invokeWbtc(abi.encodeWithSignature("mint(address,uint256)", user, USER_FUNDS));
        _invokeWbtc(abi.encodeWithSignature("mint(address,uint256)", morpho, MORPHO_LIQUIDITY));
        controller.invoke(wbtc, abi.encodeWithSignature("approve(address,uint256)", target, type(uint256).max));
        controller.invoke(wbtc, abi.encodeWithSignature("approve(address,uint256)", address(wrapper), type(uint256).max));
    }

    function _firstOwnerDeposit() private {
        bytes memory minted = controller.invoke(target, abi.encodeWithSignature("deposit(uint256)", uint256(700_000_000)));
        require(abi.decode(minted, (uint256)) == 700_000_000, "initial shares");
        controller.invoke(
            target, abi.encodeWithSignature("approve(address,uint256)", address(custodian), type(uint256).max)
        );
        custodian.collect(target, address(controller), 700_000_000);
    }

    function _userDeposit(uint256 amount, uint256 expectedShares) private {
        vm.startBroadcast(USER_KEY);
        require(ISetupToken(wbtc).approve(address(wrapper), amount), "user approval");
        uint256 shares = wrapper.deposit(wbtc, target, address(custodian), amount);
        require(shares == expectedShares, "user shares");
        vm.stopBroadcast();
    }

    function _openRound(uint256 strike, uint256 premium, uint256 vaultAmount) private {
        uint256[] memory strikes = new uint256[](1);
        strikes[0] = strike;
        controller.invoke(target, abi.encodeWithSelector(bytes4(0x40777f07), strikes, premium, vaultAmount));
    }

    function _invokeWbtc(bytes memory callData) private {
        bytes memory result = controller.invoke(wbtc, callData);
        require(result.length == 0 || abi.decode(result, (bool)), "WBTC call");
    }

    function _seedEpoch1() private {
        _report(20_731, 2_965_460_821_488, 1_654_437_317, true);
    }

    function _seedEpoch2() private {
        _report(10_499, 6_112_172_099_566, 1_636_149_374, false);
        _report(20_997, 2_896_205_000_000, 1_654_938_165, true);
        _report(15_748, 3_775_787_819_172, 1_645_588_510, false);
        _report(18_372, 4_052_482_219_401, 1_650_592_569, false);
        _report(19_684, 3_050_572_343_049, 1_652_447_858, false);
        _report(20_340, 2_940_000_000_000, 1_653_580_506, false);
        _report(20_668, 3_005_297_000_000, 1_654_251_905, false);
        _report(20_832, 3_065_956_982_724, 1_654_630_745, false);
        _report(20_914, 3_026_069_851_555, 1_654_746_908, false);
        _report(20_955, 3_007_232_000_000, 1_654_847_736, false);
        _report(20_976, 2_912_270_902_996, 1_654_883_719, false);
        _report(20_965, 2_967_150_640_295, 1_654_865_712, false);
        _report(20_960, 2_997_500_000_000, 1_654_858_511, false);
        _report(20_957, 3_001_991_583_436, 1_654_851_373, false);
        _report(20_956, 3_004_819_000_000, 1_654_848_012, false);
    }

    function _seedEpoch3() private {
        _report(11_172, 5_849_167_796_670, 1_637_394_905, false);
        _report(22_344, 2_140_829_054_395, 1_656_255_347, true);
        _report(16_758, 3_893_909_266_844, 1_647_273_335, false);
        _report(19_551, 2_774_141_615_254, 1_652_345_855, false);
        _report(20_947, 3_022_318_000_000, 1_654_830_262, false);
        _report(21_645, 2_026_302_000_000, 1_655_426_664, false);
        _report(21_994, 2_057_010_000_000, 1_655_741_958, false);
        _report(22_169, 2_039_365_000_000, 1_655_945_722, false);
        _report(22_256, 2_131_311_000_000, 1_656_078_909, false);
        _report(22_212, 2_084_789_765_536, 1_656_014_187, false);
        _report(22_234, 2_111_647_203_443, 1_656_041_679, false);
        _report(22_245, 2_103_496_000_000, 1_656_060_945, false);
        _report(22_239, 2_087_495_000_000, 1_656_050_515, false);
        _report(22_242, 2_087_491_000_000, 1_656_057_356, false);
        _report(22_243, 2_090_390_400_000, 1_656_057_607, false);
    }

    function _seedEpoch4() private {
        _report(11_468, 5_419_533_696_188, 1_637_931_334, false);
        _report(22_936, 2_181_255_000_000, 1_657_296_507, true);
        _report(17_202, 4_399_230_002_243, 1_648_162_666, false);
        _report(20_069, 3_035_140_000_000, 1_653_053_139, false);
        _report(21_502, 2_109_456_000_000, 1_655_315_759, false);
        _report(22_219, 2_069_984_000_000, 1_656_021_322, false);
        _report(22_577, 1_952_440_000_000, 1_656_663_109, false);
        _report(22_756, 2_021_259_000_000, 1_657_007_716, false);
        _report(22_846, 2_048_075_411_628, 1_657_148_732, false);
        _report(22_891, 2_171_951_114_510, 1_657_232_367, false);
        _report(22_913, 2_145_671_000_000, 1_657_270_836, false);
        _report(22_902, 2_195_566_140_070, 1_657_248_905, false);
        _report(22_907, 2_180_660_300_000, 1_657_259_711, false);
        _report(22_910, 2_179_565_708_228, 1_657_267_209, false);
        _report(22_908, 2_180_467_483_192, 1_657_263_330, false);
        _report(22_909, 2_179_900_000_000, 1_657_266_942, false);
    }

    function _seedEpoch5() private {
        _report(11_845, 5_257_300_000_000, 1_638_588_420, false);
        _report(23_690, 2_346_554_442_283, 1_658_483_717, true);
        _report(17_767, 4_288_863_000_000, 1_649_292_920, false);
        _report(20_728, 2_968_037_800_000, 1_654_430_113, false);
        _report(22_209, 2_063_552_310_495, 1_656_012_282, false);
        _report(22_949, 2_180_485_692_928, 1_657_317_347, false);
        _report(23_319, 2_137_011_000_000, 1_657_999_037, false);
        _report(23_504, 2_263_184_148_769, 1_658_242_877, false);
        _report(23_597, 2_320_693_000_000, 1_658_350_200, false);
        _report(23_643, 2_268_692_300_000, 1_658_411_716, false);
        _report(23_666, 2_323_000_000_000, 1_658_440_509, false);
        _report(23_678, 2_294_289_195_917, 1_658_465_730, false);
        _report(23_684, 2_307_996_300_000, 1_658_476_515, false);
        _report(23_687, 2_319_229_354_661, 1_658_480_109, false);
        _report(23_685, 2_312_169_000_000, 1_658_476_884, false);
    }

    function _report(uint64 lowRound, int256 answer, uint64 timestamp, bool makeLatest) private {
        uint80 roundId = uint80((uint256(5) << 64) | lowRound);
        feed.transmit(roundId, answer, timestamp, makeLatest);
    }

    function _assertReaderCurrent(uint256 expected) private view {
        (bool ok, bytes memory result) = reader.staticcall(abi.encodeWithSelector(bytes4(0x426a8109), address(feed)));
        require(ok && abi.decode(result, (uint256)) == expected, "current price");
    }

    function _assertReaderAt(uint256 timestamp, uint256 historical, uint256 current) private view {
        (bool ok, bytes memory result) = reader.staticcall(
            abi.encodeWithSelector(bytes4(0x49fdb9d7), address(feed), timestamp)
        );
        require(ok && abi.decode(result, (uint256)) == historical, "historical price");
        _assertReaderCurrent(current);
    }

    function _assertPreExploitState() private view {
        require(target.codehash == TARGET_RUNTIME_HASH && reader.codehash == READER_RUNTIME_HASH, "runtime changed");
        require(wbtc.codehash == WBTC_RUNTIME_HASH && morpho.codehash == MORPHO_RUNTIME_HASH, "dependency runtime");
        require(ISetupToken(wbtc).balanceOf(target) == 15_179_557, "target WBTC");
        require(ISetupVault(target).totalSupply() == 0, "share supply");
        require(ISetupVault(target).balanceOf(address(custodian)) == 0, "custodian shares");
        require(_uint(target, "currentEpochAmount()") == 2_586_620_174, "epoch amount");
        require(_uint(target, "epoch()") == 5 && _uint(target, "expiry()") == 0, "epoch");
        require(_uint(target, "totalPendingExit()") == 0, "pending exit");
        require(_uint(target, "START_TIME()") == 1_653_638_400, "start time");
        require(_uint(target, "PERIOD()") == 1_209_600, "period");
        require(_address(target, "owner()") == address(controller), "owner");
        require(_address(target, "designatedMaker()") == address(controller), "maker");
        require(_address(target, "validator()") == address(0), "validator");
        require(_address(target, "feeCollector()") == address(0), "fee collector");
        require(_address(target, "aaveV2LendingPool()") == address(0), "Aave");
        require(_address(target, "COLLAT()") == wbtc, "collateral");
        require(_address(target, "priceReader()") == reader, "price reader");
        require(_address(target, "LINK_AGGREGATOR()") == address(feed), "feed");

        uint256[6] memory values = [
            uint256(1e18),
            1_008_000_000_000_000_000,
            1_010_548_324_911_826_812,
            1_019_137_985_197_501_358,
            1_025_762_381_623_028_029,
            1_032_429_836_652_485_308
        ];
        uint256[5] memory strikes = [uint256(32_000e6), 33_000e6, 25_000e6, 26_000e6, 29_000e6];
        for (uint256 i; i < values.length; ++i) {
            require(_uintArg(target, "valuePerLPX1e18(uint256)", i) == values[i], "share price");
            if (i != 0) require(_uintArg(target, "strikeX1e6(uint256)", i) == strikes[i - 1], "strike");
        }
        require(_address(morpho, "owner()") == address(controller), "Morpho owner");
        require(ISetupToken(wbtc).owner() == address(controller), "WBTC owner");
        require(ISetupToken(wbtc).balanceOf(morpho) == MORPHO_LIQUIDITY, "Morpho liquidity");
    }

    function _uint(address account, string memory signature) private view returns (uint256 value) {
        (bool ok, bytes memory result) = account.staticcall(abi.encodeWithSignature(signature));
        require(ok && result.length >= 32, signature);
        value = abi.decode(result, (uint256));
    }

    function _uintArg(address account, string memory signature, uint256 arg) private view returns (uint256 value) {
        (bool ok, bytes memory result) = account.staticcall(abi.encodeWithSignature(signature, arg));
        require(ok && result.length >= 32, signature);
        value = abi.decode(result, (uint256));
    }

    function _address(address account, string memory signature) private view returns (address value) {
        (bool ok, bytes memory result) = account.staticcall(abi.encodeWithSignature(signature));
        require(ok && result.length >= 32, signature);
        value = abi.decode(result, (address));
    }

    function _runtime(string memory path) private view returns (bytes memory) {
        bytes memory encoded = bytes(vm.readFile(path));
        while (encoded.length != 0 && uint8(encoded[encoded.length - 1]) <= 0x20) {
            assembly ("memory-safe") { mstore(encoded, sub(mload(encoded), 1)) }
        }
        return vm.parseBytes(string(encoded));
    }

    function _replaceAddress(bytes memory data, address from, address to, uint256 expected) private pure {
        bytes20 needle = bytes20(from);
        bytes20 replacement = bytes20(to);
        uint256 found;
        for (uint256 i; i + 20 <= data.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < 20; ++j) {
                if (data[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (!match_) continue;
            for (uint256 j; j < 20; ++j) data[i + j] = replacement[j];
            ++found;
            i += 19;
        }
        require(found == expected, "relocation count");
    }
}
