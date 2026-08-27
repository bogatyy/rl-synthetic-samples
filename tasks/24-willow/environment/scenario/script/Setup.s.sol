// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/WillowRewards.sol";
import "../src/WillowProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        vm.startBroadcast(KEY);
        WillowGateway gateway = new WillowGateway();
        LocalToken cash = new LocalToken("Willow Settlement Cash", "CASH", 18);
        LocalToken stake = new LocalToken("Willow Staking Asset", "WSTAKE", 18);
        LocalToken bonus = new LocalToken("Willow Bonus Asset", "WBONUS", 18);
        FeeFlashBank bank = new FeeFlashBank(address(stake), 0);
        LocalPair pair = new LocalPair(address(cash), address(stake));
        WillowRewardReserve reserve = new WillowRewardReserve();
        address[] memory rewards = new address[](2);
        rewards[0] = address(cash);
        rewards[1] = address(bonus);
        WillowStakeVault vault = new WillowStakeVault(address(stake), address(reserve), rewards);
        WillowAccountFactory accountFactory = new WillowAccountFactory();
        (bytes32 root, uint256 riskA, uint256 riskB, uint256 riskC, uint256 riskD) =
            _membershipConfiguration(accountFactory);
        WillowMembership membership = new WillowMembership(root, 20, riskA, riskB, riskC, riskD);
        WillowTransferController transferController = new WillowTransferController(address(vault), address(membership));
        WillowRewardScheduler scheduler = new WillowRewardScheduler(address(vault), address(cash), address(bonus));
        WillowStakeRouter router = new WillowStakeRouter(address(cash), address(stake), address(pair), address(vault));

        cash.mint(address(pair), 5_000_000 ether);
        stake.mint(address(pair), 5_000_000 ether);
        pair.sync();
        stake.mint(address(bank), 1_500_000 ether);
        cash.mint(address(reserve), 1_000_000 ether);
        bonus.mint(address(reserve), 1_000_000 ether);
        stake.mint(DEPLOYER, 1_000_000 ether);
        stake.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, DEPLOYER);

        reserve.bind(address(vault));
        vault.bindTransferController(address(transferController));
        vault.bindScheduler(address(scheduler));
        gateway.configure(
            address(cash),
            address(stake),
            address(reserve),
            address(bank),
            address(pair),
            address(vault),
            address(scheduler),
            address(router),
            address(accountFactory),
            address(membership)
        );
        transferController.registerGateway(address(gateway));
        cash.renounceAdministration();
        stake.renounceAdministration();
        bonus.renounceAdministration();
        vm.stopBroadcast();
    }

    function _membershipConfiguration(WillowAccountFactory factory)
        private
        view
        returns (bytes32 root, uint256 riskA, uint256 riskB, uint256 riskC, uint256 riskD)
    {
        uint16[20] memory selected = _selected();
        bytes32[] memory nodes = new bytes32[](256);
        for (uint256 i; i < nodes.length; ++i) {
            uint80 code = WillowEligibility.code(i);
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

    function _selected() private pure returns (uint16[20] memory indices) {
        indices = [uint16(3), 11, 29, 42, 58, 77, 91, 104, 119, 133, 146, 157, 169, 181, 194, 207, 219, 231, 244, 253];
    }
}
