// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./QuartzRange.sol";

contract QuartzDebtBook {
    struct Record {
        uint128 amount;
        uint128 cost;
        uint32 maturity;
        uint16 durationScore;
        uint16 lossScore;
        uint8 bucket;
        bool consumed;
    }

    address public administrator = msg.sender;
    address public lender;
    mapping(uint256 => Record) public records;
    mapping(uint256 => uint256) private recordIndexPlusOne;
    uint256[] private recordIds;
    uint256 public recordCount;
    bytes32 public recordRoot;

    event BadDebtRecorded(
        uint256 indexed id,
        uint8 indexed bucket,
        uint256 amount,
        uint256 cost,
        uint32 maturity,
        uint16 durationScore,
        uint16 lossScore
    );

    function bind(address lender_) external {
        require(msg.sender == administrator && lender == address(0), "administrator");
        lender = lender_;
    }

    function record(uint256 id, uint8 bucket, uint128 amount, uint128 cost, uint32 maturity) external {
        require(msg.sender == administrator && records[id].amount == 0, "record");
        (uint16 durationScore, uint16 lossScore) = riskScores(id);
        require(bucket < 4 && cost != 0, "record values");
        records[id] = Record(amount, cost, maturity, durationScore, lossScore, bucket, false);
        recordIndexPlusOne[id] = recordIds.length + 1;
        recordIds.push(id);
        ++recordCount;
        emit BadDebtRecorded(id, bucket, amount, cost, maturity, durationScore, lossScore);
    }

    function riskScores(uint256 id) public pure returns (uint16 durationScore, uint16 lossScore) {
        durationScore = uint16(500 + uint256(keccak256(abi.encode(id, uint8(1)))) % 8_500);
        lossScore = uint16(500 + uint256(keccak256(abi.encode(id, uint8(2)))) % 8_500);
    }

    function freeze() external {
        require(msg.sender == administrator, "administrator");
        uint256 width = 1;
        while (width < recordIds.length) width <<= 1;
        bytes32[] memory nodes = new bytes32[](width);
        for (uint256 i; i < recordIds.length; ++i) {
            nodes[i] = leaf(recordIds[i]);
        }
        while (width > 1) {
            for (uint256 i; i < width; i += 2) {
                nodes[i >> 1] = keccak256(abi.encodePacked(nodes[i], nodes[i + 1]));
            }
            width >>= 1;
        }
        recordRoot = nodes[0];
        administrator = address(0);
    }

    function leaf(uint256 id) public view returns (bytes32) {
        Record memory item = records[id];
        return keccak256(
            abi.encode(id, item.bucket, item.amount, item.cost, item.maturity, item.durationScore, item.lossScore)
        );
    }

    function consume(uint256 id, bytes32[] calldata proof)
        external
        returns (uint8 bucket, uint256 amount, uint256 cost, uint256 durationScore, uint256 lossScore)
    {
        require(msg.sender == lender, "lender");
        Record storage item = records[id];
        require(!item.consumed && item.amount != 0 && block.number >= item.maturity, "record");
        uint256 stored = recordIndexPlusOne[id];
        require(stored != 0, "index");
        bytes32 node = leaf(id);
        uint256 index = stored - 1;
        for (uint256 i; i < proof.length; ++i) {
            node = index & 1 == 0
                ? keccak256(abi.encodePacked(node, proof[i]))
                : keccak256(abi.encodePacked(proof[i], node));
            index >>= 1;
        }
        require(node == recordRoot && index == 0, "record proof");
        item.consumed = true;
        bucket = item.bucket;
        amount = item.amount;
        cost = item.cost;
        durationScore = item.durationScore;
        lossScore = item.lossScore;
    }
}

contract QuartzRestructurePolicy {
    address public administrator = msg.sender;
    address public lender;
    uint256 public requiredCount;
    uint256 public requiredAmount;
    uint256 public requiredCost;
    uint256 public requiredDuration;
    uint256 public requiredLoss;
    mapping(address => uint256) public recordCount;
    mapping(address => uint256) public totalAmount;
    mapping(address => uint256) public totalCost;
    mapping(address => uint256) public totalDuration;
    mapping(address => uint256) public totalLoss;
    mapping(address => mapping(uint8 => uint256)) public bucketCount;

    function configure(address lender_, uint256 count, uint256 amount, uint256 cost, uint256 duration, uint256 loss)
        external
    {
        require(
            msg.sender == administrator && lender_ != address(0) && count != 0 && amount != 0 && cost != 0
                && duration != 0 && loss != 0,
            "configuration"
        );
        lender = lender_;
        requiredCount = count;
        requiredAmount = amount;
        requiredCost = cost;
        requiredDuration = duration;
        requiredLoss = loss;
        administrator = address(0);
    }

    function record(address account, uint8 bucket, uint256 amount, uint256 cost, uint256 duration, uint256 loss)
        external
    {
        require(msg.sender == lender && recordCount[account] < requiredCount, "lender");
        ++recordCount[account];
        ++bucketCount[account][bucket];
        totalAmount[account] += amount;
        totalCost[account] += cost;
        totalDuration[account] += duration;
        totalLoss[account] += loss;
    }

    function cleared(address account) external view returns (bool) {
        if (
            recordCount[account] != requiredCount || totalAmount[account] != requiredAmount
                || totalCost[account] != requiredCost || totalDuration[account] != requiredDuration
                || totalLoss[account] != requiredLoss
        ) return false;
        for (uint8 bucket; bucket < 4; ++bucket) {
            if (bucketCount[account][bucket] != 14) return false;
        }
        return true;
    }
}

contract QuartzCollateralRegistry {
    address public immutable engine;
    address public lender;
    mapping(uint256 => address) public borrower;

    constructor(address engine_) {
        engine = engine_;
    }

    function bind(address lender_) external {
        require(lender == address(0), "bound");
        lender = lender_;
    }

    function deposit(uint256 id, address owner) external {
        require(msg.sender == lender && QuartzPositionEngine(engine).ownerOf(id) == address(this), "custody");
        borrower[id] = owner;
    }
}

contract QuartzPositionLender {
    uint256 public constant RANGE_DEBT_LIMIT = 300_000 ether;
    address public administrator = msg.sender;
    address public settlementAsset;
    address public quoteAsset;
    address public liquidityBank;
    address public venue;
    address public engine;
    address public registry;
    address public debtBook;
    address public restructurePolicy;
    address public protectedReserve;
    uint256[4] public systemDebt =
        [uint256(690_000 ether), uint256(690_000 ether), uint256(690_000 ether), uint256(690_000 ether)];
    uint256 public constant BUCKET_DEBT_CEILING = 700_000 ether;
    uint256 public constant MAX_RESTRUCTURES = 72;
    mapping(uint256 => uint256) public debt;
    mapping(bytes32 => uint256) public rangeDebt;
    mapping(address => uint256) public restructureCount;

    function configure(
        address cash,
        address quote,
        address bank,
        address venue_,
        address engine_,
        address registry_,
        address book,
        address policy
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        quoteAsset = quote;
        liquidityBank = bank;
        venue = venue_;
        engine = engine_;
        registry = registry_;
        debtBook = book;
        restructurePolicy = policy;
        protectedReserve = address(this);
        administrator = address(0);
    }

    function depositPosition(uint256 id) external {
        require(QuartzPositionEngine(engine).ownerOf(id) == registry, "custody");
        QuartzCollateralRegistry(registry).deposit(id, msg.sender);
    }

    function restructureBadDebt(uint256 id, bytes32[] calldata proof) external {
        require(++restructureCount[msg.sender] <= MAX_RESTRUCTURES, "restructure limit");
        (uint8 bucket, uint256 amount, uint256 cost, uint256 duration, uint256 loss) =
            QuartzDebtBook(debtBook).consume(id, proof);
        IERC20Like(quoteAsset).transferFrom(msg.sender, debtBook, cost);
        systemDebt[bucket] -= amount;
        QuartzRestructurePolicy(restructurePolicy).record(msg.sender, bucket, amount, cost, duration, loss);
    }

    function borrow(uint256 id, uint256 amount, address receiver) external {
        require(QuartzCollateralRegistry(registry).borrower(id) == msg.sender, "borrower");
        require(QuartzRestructurePolicy(restructurePolicy).cleared(msg.sender), "restructure policy");
        require(debt[id] + amount <= QuartzPositionEngine(engine).value(id) * 8_500 / 10_000, "health");
        (,,,, int24 lower, int24 upper,) = QuartzPositionEngine(engine).positions(id);
        bytes32 range = keccak256(abi.encode(lower, upper));
        require(lower >= -800 && lower < 800, "bucket range");
        uint8 bucket = uint8(uint24(lower + 800) / 400);
        require(rangeDebt[range] + amount <= RANGE_DEBT_LIMIT, "range exposure");
        require(systemDebt[bucket] + amount <= BUCKET_DEBT_CEILING, "bucket ceiling");
        debt[id] += amount;
        rangeDebt[range] += amount;
        systemDebt[bucket] += amount;
        IERC20Like(settlementAsset).transfer(receiver, amount);
    }
}
