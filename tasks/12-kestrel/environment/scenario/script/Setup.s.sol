// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/KestrelMarket.sol";
import "../src/KestrelDebt.sol";
import "../src/KestrelProtocol.sol";

interface Vm {
    function startBroadcast(uint256 key) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 private constant POSITION_COUNT = 368;

    function run() external {
        vm.startBroadcast(KEY);
        KestrelEntry entry = new KestrelEntry();
        LocalToken cash = new LocalToken("Kestrel Settlement Cash", "CASH", 18);
        LocalToken[3] memory payments = [
            new LocalToken("Kestrel Note Alpha", "KNA", 18),
            new LocalToken("Kestrel Note Beta", "KNB", 18),
            new LocalToken("Kestrel Note Gamma", "KNG", 18)
        ];

        address[] memory loanAssets = new address[](4);
        loanAssets[0] = address(cash);
        for (uint256 i; i < 3; ++i) {
            loanAssets[i + 1] = address(payments[i]);
        }
        MultiFlashBank bank = new MultiFlashBank(loanAssets, 5);

        KestrelStablePool[3] memory venues = [
            new KestrelStablePool(address(cash), address(payments[0])),
            new KestrelStablePool(address(cash), address(payments[1])),
            new KestrelStablePool(address(cash), address(payments[2]))
        ];
        KestrelStrategy primary = new KestrelStrategy(address(cash));
        KestrelStrategy secondary = new KestrelStrategy(address(cash));
        KestrelCollector[3] memory collectors = [
            new KestrelCollector(address(payments[0])),
            new KestrelCollector(address(payments[1])),
            new KestrelCollector(address(payments[2]))
        ];
        KestrelInstrumentRegistry registry = new KestrelInstrumentRegistry();
        KestrelDebtLedger ledger = new KestrelDebtLedger(address(registry));
        KestrelAllocationAdvisor advisor =
            new KestrelAllocationAdvisor(address(ledger), address(registry), address(primary), address(secondary));
        KestrelAccountingRouter accounting =
            new KestrelAccountingRouter(address(cash), address(registry), address(ledger));
        KestrelAllocationVault vault = new KestrelAllocationVault(
            address(cash), address(ledger), address(advisor), address(accounting), address(primary)
        );

        primary.bind(address(vault));
        secondary.bind(address(vault));
        for (uint8 instrument; instrument < 12; ++instrument) {
            uint256 paymentIndex = instrument % 3;
            uint96 faceUnit = instrument == 7 ? uint96(100 ether) : uint96(1 ether);
            registry.configure(
                instrument,
                address(payments[paymentIndex]),
                address(collectors[paymentIndex]),
                faceUnit,
                uint96(1 ether),
                uint16(6_500 + uint256(instrument) * 250)
            );
        }
        registry.freeze();

        cash.mint(DEPLOYER, 6_500_000 ether);
        cash.mint(address(bank), 3_500_000 ether);
        for (uint256 i; i < 3; ++i) {
            payments[i].mint(DEPLOYER, 300_000 ether);
            payments[i].mint(address(bank), 80_000 ether);
            cash.approve(address(venues[i]), type(uint256).max);
            payments[i].approve(address(venues[i]), type(uint256).max);
            venues[i].seed(500_000 ether, 300_000 ether);
        }

        cash.approve(address(vault), type(uint256).max);
        vault.bootstrap(5_000_000 ether, 1_000_000 ether, DEPLOYER);

        uint16[48] memory selected = [
            uint16(60),
            336,
            240,
            25,
            205,
            181,
            85,
            350,
            50,
            75,
            51,
            255,
            231,
            111,
            220,
            100,
            76,
            280,
            245,
            125,
            101,
            246,
            150,
            330,
            30,
            102,
            55,
            355,
            235,
            115,
            295,
            271,
            175,
            151,
            31,
            331,
            307,
            211,
            140,
            116,
            320,
            285,
            165,
            310,
            10,
            155,
            335,
            35
        ];
        for (uint256 i; i < POSITION_COUNT; ++i) {
            uint8 instrument = uint8(i % 12);
            uint112 face = instrument == 7
                ? uint112((1_800 + (i % 7) * 25) * 100 ether)
                : uint112((1_700 + (i % 13) * 35) * 1 ether);
            uint96 payment = uint96((75 + (i % 5) * 5) * 1 ether);
            uint32 maturity = i % 9 == 0 ? type(uint32).max : uint32(block.number);
            address account = address(uint160(uint256(keccak256(abi.encode("Kestrel credit account", i)))));
            uint256 entropy = uint256(keccak256(abi.encode("Kestrel position risk", i)));
            uint24 riskA = uint24(100 + entropy % 900);
            uint24 riskB = uint24(100 + (entropy >> 48) % 900);
            uint24 riskC = uint24(100 + (entropy >> 96) % 900);
            uint24 riskD = uint24(100 + (entropy >> 144) % 900);
            ledger.open(account, face, payment, maturity, instrument, riskA, riskB, riskC, riskD);
        }
        uint256 migrationRemoval;
        uint256 scoreA;
        uint256 scoreB;
        uint256 scoreC;
        uint256 scoreD;
        for (uint256 i; i < selected.length; ++i) {
            address account = address(uint160(uint256(keccak256(abi.encode("Kestrel credit account", selected[i])))));
            (uint112 face,,,, uint24 riskA, uint24 riskB, uint24 riskC, uint24 riskD, bool open) =
                ledger.positions(account);
            require(open, "selected position");
            migrationRemoval += face;
            scoreA += riskA;
            scoreB += riskB;
            scoreC += riskC;
            scoreD += riskD;
        }
        uint256 remainingExposure = ledger.callableExposure() - migrationRemoval;
        advisor.setMigrationPolicy(
            remainingExposure - 1 ether,
            remainingExposure + 1 ether,
            scoreA,
            scoreA,
            scoreB,
            scoreB,
            scoreC,
            scoreC,
            scoreD,
            scoreD
        );
        ledger.freeze();

        address[3] memory paymentAddresses;
        address[3] memory venueAddresses;
        for (uint256 i; i < 3; ++i) {
            paymentAddresses[i] = address(payments[i]);
            venueAddresses[i] = address(venues[i]);
        }
        entry.configure(
            address(cash),
            address(vault),
            address(bank),
            address(ledger),
            address(registry),
            address(advisor),
            address(accounting),
            paymentAddresses,
            venueAddresses
        );
        accounting.registerConsumers(address(entry), address(vault));
        cash.renounceAdministration();
        for (uint256 i; i < 3; ++i) {
            payments[i].renounceAdministration();
        }
        vm.stopBroadcast();
    }
}
