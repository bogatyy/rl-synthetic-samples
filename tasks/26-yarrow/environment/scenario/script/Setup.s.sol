// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/YarrowEnvelope.sol";
import "../src/YarrowCustody.sol";
import "../src/YarrowVenues.sol";
import "../src/YarrowProtocol.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant TRANSPORT = 0x75A683B2c7E37E46542A541bAb16c934b55a4a56;

    function run() external {
        vm.startBroadcast(KEY);
        YarrowBridgeRouter bridge = new YarrowBridgeRouter();
        LocalToken cash = new LocalToken("Yarrow Settlement Cash", "CASH", 18);
        LocalToken receipt = new LocalToken("Yarrow Custody Receipt", "ycCASH", 18);
        YarrowEnvelopeVerifier verifier = new YarrowEnvelopeVerifier();
        YarrowVenueRegistry registry = new YarrowVenueRegistry();
        YarrowSessionLedger sessions = new YarrowSessionLedger(address(registry));
        YarrowTokenAdapter adapter = new YarrowTokenAdapter(address(registry), address(receipt));
        YarrowAccountRouter accounts = new YarrowAccountRouter();
        YarrowActionModule module = new YarrowActionModule(address(accounts), address(registry), address(sessions));
        YarrowCustodyAccount custody = new YarrowCustodyAccount(address(accounts), address(adapter), address(cash));
        YarrowQuoteVenue quote = new YarrowQuoteVenue(address(sessions));
        YarrowSettlementVenue settlement =
            new YarrowSettlementVenue(address(sessions), address(adapter), address(cash));
        YarrowFinalizeVenue finalize = new YarrowFinalizeVenue(address(sessions));
        YarrowAccountingVenue inventory = new YarrowAccountingVenue(1, keccak256("inventory-observer"));
        YarrowAccountingVenue reconciliation = new YarrowAccountingVenue(4, keccak256("reconciliation-only"));

        bytes32 accountId = keccak256("yarrow-primary-custody-v3");
        verifier.configure(TRANSPORT, 43_114, 1, bytes("settlement://primary/finality-v3"));
        accounts.configure(address(bridge), address(module), accountId, address(custody));
        registry.configureModule(address(module));
        registry.approveVenue(address(inventory));
        registry.approveVenue(address(quote));
        registry.approveVenue(address(reconciliation));
        registry.approveVenue(address(settlement));
        registry.approveVenue(address(finalize));
        registry.finishConfiguration();
        bridge.configure(address(cash), address(custody), address(verifier), address(accounts), accountId);

        receipt.setMinter(address(adapter), true);
        cash.mint(address(custody), 3_000_000 ether);
        cash.renounceAdministration();
        receipt.renounceAdministration();
        vm.stopBroadcast();
    }
}
