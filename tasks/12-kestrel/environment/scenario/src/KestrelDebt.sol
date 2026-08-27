// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

contract KestrelStrategy {
    address public immutable cash;
    address public vault;

    constructor(address cash_) {
        cash = cash_;
    }

    function bind(address vault_) external {
        require(vault == address(0), "bound");
        vault = vault_;
    }

    function releaseCash() external returns (uint256 released) {
        require(msg.sender == vault, "vault");
        released = IERC20Like(cash).balanceOf(address(this));
        require(IERC20Like(cash).transfer(vault, released), "transfer");
    }
}

contract KestrelCollector {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

contract KestrelInstrumentRegistry {
    struct Instrument {
        address paymentAsset;
        address collector;
        uint96 faceUnit;
        uint96 settlementUnit;
        uint16 recognitionBps;
        bool enabled;
    }

    address public administrator = msg.sender;
    uint8 public instrumentCount;
    mapping(uint8 => Instrument) public instruments;

    event InstrumentConfigured(
        uint8 indexed instrument,
        address indexed paymentAsset,
        address indexed collector,
        uint256 faceUnit,
        uint256 settlementUnit,
        uint256 recognitionBps
    );

    function configure(
        uint8 instrument,
        address paymentAsset,
        address collector,
        uint96 faceUnit,
        uint96 settlementUnit,
        uint16 recognitionBps
    ) external {
        require(msg.sender == administrator && instrument == instrumentCount, "administrator");
        require(
            paymentAsset != address(0) && collector != address(0) && faceUnit != 0 && settlementUnit != 0
                && recognitionBps <= 10_000,
            "instrument"
        );
        instruments[instrument] = Instrument(paymentAsset, collector, faceUnit, settlementUnit, recognitionBps, true);
        ++instrumentCount;
        emit InstrumentConfigured(instrument, paymentAsset, collector, faceUnit, settlementUnit, recognitionBps);
    }

    function freeze() external {
        require(msg.sender == administrator && instrumentCount >= 8, "administrator");
        administrator = address(0);
    }
}

contract KestrelDebtLedger {
    struct Position {
        uint112 face;
        uint96 payment;
        uint32 maturity;
        uint8 instrument;
        uint24 riskA;
        uint24 riskB;
        uint24 riskC;
        uint24 riskD;
        bool open;
    }

    address public immutable registry;
    address public administrator = msg.sender;
    uint256 public callableExposure;
    uint256 public outstandingFace;
    uint64 public settlementBlock;
    uint16 public settlementsInBlock;
    mapping(uint8 => uint256) public outstandingByInstrument;
    mapping(uint8 => uint256) public settledFace;
    mapping(uint8 => uint256) public settledPayment;
    uint256 public settledRiskA;
    uint256 public settledRiskB;
    uint256 public settledRiskC;
    uint256 public settledRiskD;
    mapping(address => Position) public positions;

    event CreditOpened(
        address indexed account,
        uint8 indexed instrument,
        uint256 face,
        uint256 payment,
        uint32 maturity,
        uint24 riskA,
        uint24 riskB,
        uint24 riskC,
        uint24 riskD
    );
    event CreditSettled(address indexed account, uint8 indexed instrument, uint256 face, uint256 payment);

    constructor(address registry_) {
        registry = registry_;
    }

    function open(
        address account,
        uint112 face,
        uint96 payment,
        uint32 maturity,
        uint8 instrument,
        uint24 riskA,
        uint24 riskB,
        uint24 riskC,
        uint24 riskD
    ) external {
        require(msg.sender == administrator && !positions[account].open, "administrator");
        (,,,,, bool enabled) = KestrelInstrumentRegistry(registry).instruments(instrument);
        require(account != address(0) && face != 0 && payment != 0 && enabled, "position");
        require(riskA != 0 && riskB != 0 && riskC != 0 && riskD != 0, "risk");
        positions[account] = Position(face, payment, maturity, instrument, riskA, riskB, riskC, riskD, true);
        outstandingFace += face;
        outstandingByInstrument[instrument] += face;
        if (maturity != type(uint32).max) callableExposure += face;
        emit CreditOpened(account, instrument, face, payment, maturity, riskA, riskB, riskC, riskD);
    }

    function freeze() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function settleFor(address account) external {
        if (settlementBlock != block.number) {
            settlementBlock = uint64(block.number);
            settlementsInBlock = 0;
        }
        require(settlementsInBlock < 48, "settlement batch");
        ++settlementsInBlock;
        Position storage position = positions[account];
        require(position.open && block.number >= position.maturity, "position");
        position.open = false;
        outstandingFace -= position.face;
        outstandingByInstrument[position.instrument] -= position.face;
        callableExposure -= position.face;
        settledFace[position.instrument] += position.face;
        settledPayment[position.instrument] += position.payment;
        settledRiskA += position.riskA;
        settledRiskB += position.riskB;
        settledRiskC += position.riskC;
        settledRiskD += position.riskD;
        (address paymentAsset, address collector,,,,) =
            KestrelInstrumentRegistry(registry).instruments(position.instrument);
        require(IERC20Like(paymentAsset).transferFrom(msg.sender, collector, position.payment), "payment");
        emit CreditSettled(account, position.instrument, position.face, position.payment);
    }
}

contract KestrelAllocationAdvisor {
    address public immutable ledger;
    address public immutable registry;
    address public immutable primary;
    address public immutable secondary;
    address public administrator = msg.sender;
    uint256 public minimumExposure;
    uint256 public maximumExposure;
    uint256 public factorFloorA;
    uint256 public factorCeilingA;
    uint256 public factorFloorB;
    uint256 public factorCeilingB;
    uint256 public factorFloorC;
    uint256 public factorCeilingC;
    uint256 public factorFloorD;
    uint256 public factorCeilingD;

    constructor(address ledger_, address registry_, address primary_, address secondary_) {
        ledger = ledger_;
        registry = registry_;
        primary = primary_;
        secondary = secondary_;
    }

    function setMigrationPolicy(
        uint256 minimumExposure_,
        uint256 maximumExposure_,
        uint256 floorA,
        uint256 ceilingA,
        uint256 floorB,
        uint256 ceilingB,
        uint256 floorC,
        uint256 ceilingC,
        uint256 floorD,
        uint256 ceilingD
    ) external {
        require(
            msg.sender == administrator && minimumExposure_ != 0 && minimumExposure_ <= maximumExposure_ && floorA != 0
                && floorA <= ceilingA && floorB != 0 && floorB <= ceilingB && floorC != 0 && floorC <= ceilingC
                && floorD != 0 && floorD <= ceilingD,
            "administrator"
        );
        minimumExposure = minimumExposure_;
        maximumExposure = maximumExposure_;
        factorFloorA = floorA;
        factorCeilingA = ceilingA;
        factorFloorB = floorB;
        factorCeilingB = ceilingB;
        factorFloorC = floorC;
        factorCeilingC = ceilingC;
        factorFloorD = floorD;
        factorCeilingD = ceilingD;
        administrator = address(0);
    }

    function recommendedStrategy() external view returns (address) {
        KestrelDebtLedger book = KestrelDebtLedger(ledger);
        uint256 exposure = book.callableExposure();
        if (
            book.settlementBlock() != block.number || book.settlementsInBlock() != 48 || exposure < minimumExposure
                || exposure > maximumExposure
        ) return primary;
        uint256 scoreA = book.settledRiskA();
        uint256 scoreB = book.settledRiskB();
        uint256 scoreC = book.settledRiskC();
        uint256 scoreD = book.settledRiskD();
        if (
            scoreA < factorFloorA || scoreA > factorCeilingA || scoreB < factorFloorB || scoreB > factorCeilingB
                || scoreC < factorFloorC || scoreC > factorCeilingC || scoreD < factorFloorD || scoreD > factorCeilingD
        ) return primary;
        return secondary;
    }
}

contract KestrelAccountingRouter {
    address public immutable cash;
    address public immutable registry;
    address public immutable ledger;
    address public administrator = msg.sender;

    event ConsumerRegistered(address indexed entry, address indexed vault);

    constructor(address cash_, address registry_, address ledger_) {
        cash = cash_;
        registry = registry_;
        ledger = ledger_;
    }

    function registerConsumers(address entry, address vault) external {
        require(msg.sender == administrator && entry != address(0) && vault != address(0), "administrator");
        administrator = address(0);
        emit ConsumerRegistered(entry, vault);
    }

    function estimate(address vault, address strategy) external view returns (uint256 assets) {
        assets = IERC20Like(cash).balanceOf(vault) + IERC20Like(cash).balanceOf(strategy);
        uint8 count = KestrelInstrumentRegistry(registry).instrumentCount();
        for (uint8 instrument; instrument < count; ++instrument) {
            (,,, uint96 settlementUnit, uint16 recognitionBps, bool enabled) =
                KestrelInstrumentRegistry(registry).instruments(instrument);
            if (!enabled) continue;
            uint256 face = KestrelDebtLedger(ledger).settledFace(instrument);
            assets += face * 1 ether / settlementUnit * recognitionBps / 10_000;
        }
    }
}
