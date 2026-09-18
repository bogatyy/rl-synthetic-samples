// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VDimensionExactRuntime, VDimensionLibraryExactRuntime} from "../src/ExactRuntime.sol";
import {Vollar} from "../src/Vollar/AVD(2025-7-3) (BSC).sol";
import {FixtureStable, MarketPair, MarketRouter, MoolahFlashLender, LockedAuthority} from "../src/MarketContracts.sol";

interface Vm {
    function startBroadcast(uint256 key) external;
    function stopBroadcast() external;
    function readFile(string calldata path) external view returns (string memory);
    function parseBytes(string calldata text) external pure returns (bytes memory);
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    address private constant TARGET = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address private constant LINKED_LIBRARY = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address private constant AVD = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    address private constant STABLE = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    address private constant PAIR = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    address private constant ROUTER = 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707;
    address private constant LENDER = 0x0165878A594ca255338adfa4d48449f69242Eb8F;
    address private constant AUTHORITY = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;

    function run() external {
        bytes memory targetRuntime = _runtime("runtime/vds-runtime.hex");
        bytes memory libraryRuntime = _runtime("runtime/vds-library-runtime.hex");
        (bytes32[] memory slots, bytes32[] memory values) = _targetState();

        vm.startBroadcast(KEY);

        VDimensionExactRuntime target = new VDimensionExactRuntime(targetRuntime, slots, values);
        require(address(target) == TARGET, "target address");

        bytes32[] memory empty = new bytes32[](0);
        VDimensionLibraryExactRuntime linked = new VDimensionLibraryExactRuntime(libraryRuntime, empty, empty);
        require(address(linked) == LINKED_LIBRARY, "library address");

        Vollar avd = new Vollar(
            TARGET,
            address(0x917a203FEb6B2d86ad4F4d9b52F03C0F8Cb2Bd73),
            address(0x6c8Abda36388b15C011d9Ee93a811D36Df8BAAAA)
        );
        require(address(avd) == AVD, "AVD address");
        FixtureStable stable = new FixtureStable();
        require(address(stable) == STABLE, "stable address");
        MarketPair pair = new MarketPair(AVD, STABLE);
        require(address(pair) == PAIR, "pair address");
        MarketRouter router = new MarketRouter(PAIR);
        require(address(router) == ROUTER, "router address");
        MoolahFlashLender lender = new MoolahFlashLender();
        require(address(lender) == LENDER, "lender address");
        LockedAuthority authority = new LockedAuthority();
        require(address(authority) == AUTHORITY, "authority address");

        // Exact pre-incident balances and market reserves. The production VDS
        // runtime above retains the original global accounting scalars; no
        // synthetic member table or grader-only state is created.
        stable.mint(DEPLOYER, 5_000_000 ether);
        avd.setTaxs(50, 200, 50, 0);
        avd.setPairAdres(PAIR);
        avd.addWhitelist(TARGET);
        avd.addWhitelistA(TARGET);
        avd.addWhitelistA(DEPLOYER);

        avd.transfer(PAIR, 268_183_693_085);
        stable.transfer(PAIR, 57_274_279_651_527_723_560_361);
        pair.sync();
        avd.transfer(TARGET, 121_159_655_473);
        stable.transfer(LENDER, 4_409_227_674_910_901_625_194_231);

        avd.removeWhitelistA(DEPLOYER);
        avd.setOwner(AUTHORITY);
        stable.transfer(AUTHORITY, stable.balanceOf(DEPLOYER));
        stable.renounceAdministration();
        (bool funded,) = AUTHORITY.call{value: DEPLOYER.balance - 100 ether}("");
        require(funded, "authority funding");

        vm.stopBroadcast();
    }

    function _runtime(string memory path) private view returns (bytes memory) {
        bytes memory encoded = bytes(vm.readFile(path));
        while (encoded.length != 0 && uint8(encoded[encoded.length - 1]) <= 0x20) {
            assembly { mstore(encoded, sub(mload(encoded), 1)) }
        }
        return vm.parseBytes(string(encoded));
    }

    function _targetState() private pure returns (bytes32[] memory slots, bytes32[] memory values) {
        // Non-zero scalar slots from block 54,252,253. Address-valued slots
        // are relocated to the equivalent local AVD and locked authority.
        uint256[64] memory indexes = [
            uint256(2),3,4,5,12,13,15,23,24,25,26,27,28,42,43,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,90,91,92,93,94,95,96,97,98,99,100,101,102,103
        ];
        bytes32[64] memory historical = [
            bytes32(uint256(0x8e3b645838)),
            bytes32(0x562d44696d656e73696f6e000000000000000000000000000000000000000016),
            bytes32(0x5644530000000000000000000000000000000000000000000000000000000006),
            bytes32(uint256(uint160(AUTHORITY))),
            bytes32(uint256(uint160(AVD))), bytes32(uint256(uint160(AVD))), bytes32(uint256(uint160(AVD))),
            bytes32(uint256(0x6865247f)), bytes32(uint256(0x176)), bytes32(uint256(0x90b8527008)),
            bytes32(uint256(0x7a43b79)), bytes32(uint256(0x2e7c92f5a)), bytes32(uint256(0x727f5303)),
            bytes32(uint256(0x989680)), bytes32(uint256(0xe8d4a51000)), bytes32(uint256(0x3b9aca00)),
            bytes32(uint256(0x2540be400)), bytes32(uint256(0x3c)), bytes32(uint256(0x278d00)),
            bytes32(uint256(0x12c)), bytes32(uint256(0x1f4)), bytes32(uint256(0x2710)),
            bytes32(uint256(0x64)), bytes32(uint256(0xc8)), bytes32(uint256(0x12c)),
            bytes32(uint256(0x190)), bytes32(uint256(0x3e8)), bytes32(uint256(0x7d0)),
            bytes32(uint256(0x1388)), bytes32(uint256(1)), bytes32(uint256(1)),
            bytes32(uint256(0x5f5e100)), bytes32(uint256(0x2540be400)), bytes32(uint256(0x77359400)),
            bytes32(uint256(0x2ba7def3000)), bytes32(uint256(0x9184e72a000)), bytes32(uint256(0x1b48eb57e000)),
            bytes32(uint256(5)), bytes32(uint256(0x32)), bytes32(uint256(0x32)),
            bytes32(uint256(0xf)), bytes32(uint256(5)), bytes32(uint256(0x46)),
            bytes32(uint256(0x5a)), bytes32(uint256(0x6e)), bytes32(uint256(0x2540be400)),
            bytes32(uint256(0x6fc23ac00)), bytes32(uint256(0x174876e800)), bytes32(uint256(0x45d964b800)),
            bytes32(uint256(0xe8d4a51000)), bytes32(uint256(0x64)), bytes32(uint256(0x14)),
            bytes32(uint256(0x14)), bytes32(uint256(0x14)), bytes32(uint256(0x14)),
            bytes32(uint256(0x14)), bytes32(uint256(0x14)), bytes32(uint256(0x5f5e100)),
            bytes32(uint256(0xbebc200)), bytes32(uint256(0x1dcd6500)), bytes32(uint256(0x3b9aca00)),
            bytes32(uint256(0x77359400)), bytes32(uint256(0x12a05f200)), bytes32(uint256(0x2540be400))
        ];
        slots = new bytes32[](indexes.length);
        values = new bytes32[](indexes.length);
        for (uint256 i; i < indexes.length; ++i) {
            slots[i] = bytes32(indexes[i]);
            values[i] = historical[i];
        }
    }
}
