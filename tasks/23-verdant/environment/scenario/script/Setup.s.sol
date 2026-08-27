// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/VerdantCurve.sol";
import "../src/VerdantProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        vm.startBroadcast(KEY);
        VerdantSaleRouter router = new VerdantSaleRouter();
        LocalToken cash = new LocalToken("Verdant Settlement Cash", "CASH", 18);
        LocalToken inventory = new LocalToken("Verdant Inventory", "VINT", 18);
        FeeFlashBank bank = new FeeFlashBank(address(cash), 6);
        VerdantSellerFactory factory = new VerdantSellerFactory();
        (bytes32 root, uint256 riskA, uint256 riskB, uint256 riskC, uint256 riskD) = _batchConfiguration(factory);
        VerdantBatchPolicy policy = new VerdantBatchPolicy(root, 24, riskA, riskB, riskC, riskD);
        VerdantDealer dealer = new VerdantDealer(address(cash), address(inventory), address(policy), address(factory));
        VerdantInventoryPool pool = new VerdantInventoryPool(address(cash), address(inventory));

        policy.bind(address(dealer));
        cash.mint(address(dealer), 3_000_000 ether);
        cash.mint(address(bank), 700_000 ether);
        cash.mint(DEPLOYER, 8_000_000 ether);
        inventory.mint(DEPLOYER, 8_000_000 ether);
        cash.approve(address(pool), type(uint256).max);
        inventory.approve(address(pool), type(uint256).max);
        pool.seed(8_000_000 ether, 8_000_000 ether);
        router.configure(
            address(cash),
            address(inventory),
            address(dealer),
            address(bank),
            address(policy),
            address(factory),
            address(pool)
        );
        cash.renounceAdministration();
        inventory.renounceAdministration();
        vm.stopBroadcast();
    }

    function _batchConfiguration(VerdantSellerFactory factory)
        private
        view
        returns (bytes32 root, uint256 riskA, uint256 riskB, uint256 riskC, uint256 riskD)
    {
        uint16[24] memory selected = _selected();
        bytes32[] memory nodes = new bytes32[](512);
        for (uint256 i; i < nodes.length; ++i) {
            uint80 code = VerdantLicenseData.code(i);
            nodes[i] = keccak256(abi.encodePacked(factory.compute(i), code));
            for (uint256 j; j < selected.length; ++j) {
                if (selected[j] != i) continue;
                riskA += uint16(code);
                riskB += uint16(code >> 16);
                riskC += uint16(code >> 32);
                riskD += uint16(code >> 48);
                break;
            }
        }
        uint256 width = nodes.length;
        while (width > 1) {
            for (uint256 i; i < width; i += 2) {
                nodes[i >> 1] = keccak256(abi.encodePacked(nodes[i], nodes[i + 1]));
            }
            width >>= 1;
        }
        root = nodes[0];
    }

    function _selected() private pure returns (uint16[24] memory indices) {
        indices = [
            uint16(5),
            19,
            37,
            58,
            76,
            94,
            117,
            139,
            161,
            183,
            204,
            226,
            247,
            269,
            291,
            312,
            334,
            356,
            378,
            401,
            423,
            445,
            476,
            507
        ];
    }
}
