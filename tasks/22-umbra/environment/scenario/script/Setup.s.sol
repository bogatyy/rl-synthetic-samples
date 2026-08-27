// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/UmbraRouting.sol";
import "../src/UmbraProtocol.sol";

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
        UmbraVaultRouter router = new UmbraVaultRouter();
        LocalToken cash = new LocalToken("Umbra Settlement Cash", "CASH", 18);
        FeeFlashBank bank = new FeeFlashBank(address(cash), 10);
        UmbraAdapterFactory factory = new UmbraAdapterFactory();
        UmbraVenueRegistry registry = new UmbraVenueRegistry(address(factory));
        UmbraRouteExecutor executor = new UmbraRouteExecutor(address(registry));
        UmbraAssetVault vault = new UmbraAssetVault(address(cash));
        LocalToken intermediate = new LocalToken("Umbra Route Credit", "URC", 18);
        UmbraFixedPlugin plugin = new UmbraFixedPlugin(address(cash), address(intermediate));

        address adapter = factory.create(address(cash), address(intermediate), address(plugin), 0);
        registry.register(adapter);
        intermediate.mint(adapter, 500_000 ether);
        cash.mint(DEPLOYER, 4_000_000 ether);
        cash.approve(address(vault), type(uint256).max);
        vault.bootstrap(4_000_000 ether, DEPLOYER);
        cash.mint(address(bank), 1_200_000 ether);
        vault.bind(address(router));
        router.configure(
            address(cash), address(vault), address(bank), address(registry), address(factory), address(executor)
        );
        cash.renounceAdministration();
        intermediate.renounceAdministration();
        vm.stopBroadcast();
    }
}
