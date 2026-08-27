// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

library VerdantLicenseData {
    function code(uint256 index) internal pure returns (uint80 value) {
        uint256 entropy = uint256(keccak256(abi.encode("Verdant seller licence", index)));
        value = uint80(uint16(1_000 + entropy % 49_001));
        value |= uint80(uint16(1_000 + (entropy >> 48) % 49_001)) << 16;
        value |= uint80(uint16(1_000 + (entropy >> 96) % 49_001)) << 32;
        value |= uint80(uint16(1_000 + (entropy >> 144) % 49_001)) << 48;
        value |= uint80(uint16((entropy >> 208) % 801)) << 64;
    }
}

interface IVerdantDealerEntry {
    function submit(address operator, uint256 index, uint80 code, bytes32[] calldata proof, uint256 amount) external;
}

contract VerdantSellerAccount {
    address public operator;
    address public inventoryToken;
    address public dealer;

    function initialize(address operator_, address token_, address dealer_) external {
        require(operator == address(0) && operator_ != address(0), "initialized");
        operator = operator_;
        inventoryToken = token_;
        dealer = dealer_;
        IERC20Like(token_).approve(dealer_, type(uint256).max);
    }

    function submit(uint256 index, uint80 code, bytes32[] calldata proof, uint256 amount) external {
        require(msg.sender == operator, "operator");
        require(IERC20Like(inventoryToken).transferFrom(operator, address(this), amount), "inventory");
        IVerdantDealerEntry(dealer).submit(operator, index, code, proof, amount);
    }
}

contract VerdantSellerFactory {
    event SellerCreated(address indexed seller, address indexed operator, uint256 indexed index);

    function deploy(uint256 index, address operator, address token, address dealer) external returns (address seller) {
        seller = address(new VerdantSellerAccount{salt: bytes32(index)}());
        VerdantSellerAccount(seller).initialize(operator, token, dealer);
        emit SellerCreated(seller, operator, index);
    }

    function compute(uint256 index) public view returns (address seller) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), bytes32(index), keccak256(type(VerdantSellerAccount).creationCode)
            )
        );
        seller = address(uint160(uint256(digest)));
    }
}

contract VerdantBatchPolicy {
    uint256 public constant ACCOUNT_LIMIT = 20_000 ether;
    bytes32 public immutable root;
    uint8 public immutable requiredSellers;
    uint256 public immutable requiredRiskA;
    uint256 public immutable requiredRiskB;
    uint256 public immutable requiredRiskC;
    uint256 public immutable requiredRiskD;
    address public dealer;

    mapping(address => bool) public usedSeller;
    mapping(uint256 => mapping(address => uint256)) public sold;
    mapping(address => uint8) public sellerCount;
    mapping(address => uint256) public riskA;
    mapping(address => uint256) public riskB;
    mapping(address => uint256) public riskC;
    mapping(address => uint256) public riskD;

    constructor(bytes32 root_, uint8 sellers, uint256 a, uint256 b, uint256 c, uint256 d) {
        require(root_ != bytes32(0) && sellers != 0 && a != 0 && b != 0 && c != 0 && d != 0, "policy");
        root = root_;
        requiredSellers = sellers;
        requiredRiskA = a;
        requiredRiskB = b;
        requiredRiskC = c;
        requiredRiskD = d;
    }

    function bind(address dealer_) external {
        require(dealer == address(0) && dealer_ != address(0), "bound");
        dealer = dealer_;
    }

    function licenseCode(uint256 index) external pure returns (uint80) {
        return VerdantLicenseData.code(index);
    }

    function record(
        address seller,
        address operator,
        uint256 index,
        uint80 code,
        bytes32[] calldata proof,
        uint256 amount
    ) external {
        require(msg.sender == dealer && index < 512 && !usedSeller[seller], "seller");
        require(code == VerdantLicenseData.code(index), "code");
        _verify(index, keccak256(abi.encodePacked(seller, code)), proof);

        uint256 next = sold[block.number][seller] + amount;
        require(amount == ACCOUNT_LIMIT && next <= ACCOUNT_LIMIT, "account limit");
        sold[block.number][seller] = next;
        usedSeller[seller] = true;

        require(sellerCount[operator] < requiredSellers, "batch full");
        ++sellerCount[operator];
        riskA[operator] += uint16(code);
        riskB[operator] += uint16(code >> 16);
        riskC[operator] += uint16(code >> 32);
        riskD[operator] += uint16(code >> 48);
    }

    function cleared(address operator) external view returns (bool) {
        return sellerCount[operator] == requiredSellers && riskA[operator] == requiredRiskA
            && riskB[operator] == requiredRiskB && riskC[operator] == requiredRiskC && riskD[operator] == requiredRiskD;
    }

    function _verify(uint256 index, bytes32 node, bytes32[] calldata proof) private view {
        for (uint256 i; i < proof.length; ++i) {
            node = index & 1 == 0
                ? keccak256(abi.encodePacked(node, proof[i]))
                : keccak256(abi.encodePacked(proof[i], node));
            index >>= 1;
        }
        require(node == root && index == 0, "proof");
    }
}

contract VerdantInventoryPool {
    address public immutable cash;
    address public immutable inventoryToken;
    uint112 public cashReserve;
    uint112 public inventoryReserve;

    constructor(address cash_, address token_) {
        cash = cash_;
        inventoryToken = token_;
    }

    function seed(uint256 cashAmount, uint256 inventoryAmount) external {
        require(cashReserve == 0 && inventoryReserve == 0, "seeded");
        require(IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount), "cash");
        require(IERC20Like(inventoryToken).transferFrom(msg.sender, address(this), inventoryAmount), "inventory");
        _sync();
    }

    function cashForExactInventory(uint256 inventoryOut) public view returns (uint256 cashIn) {
        require(inventoryOut != 0 && inventoryOut < inventoryReserve, "output");
        uint256 numerator = uint256(cashReserve) * inventoryOut * 10_000;
        uint256 denominator = (uint256(inventoryReserve) - inventoryOut) * 9_970;
        cashIn = numerator / denominator + 1;
    }

    function buyExactInventory(uint256 inventoryOut, uint256 maximumCash, address receiver)
        external
        returns (uint256 cashIn)
    {
        cashIn = cashForExactInventory(inventoryOut);
        require(cashIn <= maximumCash && receiver != address(0), "slippage");
        require(IERC20Like(cash).transferFrom(msg.sender, address(this), cashIn), "cash");
        require(IERC20Like(inventoryToken).transfer(receiver, inventoryOut), "inventory");
        _sync();
    }

    function _sync() private {
        uint256 cashBalance = IERC20Like(cash).balanceOf(address(this));
        uint256 inventoryBalance = IERC20Like(inventoryToken).balanceOf(address(this));
        require(cashBalance <= type(uint112).max && inventoryBalance <= type(uint112).max, "reserves");
        cashReserve = uint112(cashBalance);
        inventoryReserve = uint112(inventoryBalance);
    }
}

contract VerdantDealer {
    address public immutable cash;
    address public immutable inventoryToken;
    address public immutable batchPolicy;
    address public immutable sellerFactory;
    mapping(address => uint256) public pendingCash;
    uint256 public totalSubmitted;
    uint256 public totalSettled;

    constructor(address cash_, address token_, address policy_, address factory_) {
        cash = cash_;
        inventoryToken = token_;
        batchPolicy = policy_;
        sellerFactory = factory_;
    }

    function previewSubmit(uint80 code, uint256 amount) public pure returns (uint256 cashOut) {
        uint256 premium = uint16(code >> 64);
        cashOut = amount * (12_400 + premium) / 10_000;
    }

    function submit(address operator, uint256 index, uint80 code, bytes32[] calldata proof, uint256 amount) external {
        require(msg.sender == VerdantSellerFactory(sellerFactory).compute(index), "seller address");
        require(VerdantSellerAccount(msg.sender).operator() == operator, "operator");
        VerdantBatchPolicy(batchPolicy).record(msg.sender, operator, index, code, proof, amount);
        require(IERC20Like(inventoryToken).transferFrom(msg.sender, address(this), amount), "inventory");
        pendingCash[operator] += previewSubmit(code, amount);
        totalSubmitted += amount;
    }

    function settle(address receiver) external returns (uint256 cashOut) {
        require(VerdantBatchPolicy(batchPolicy).cleared(msg.sender), "batch policy");
        cashOut = pendingCash[msg.sender];
        require(cashOut != 0 && receiver != address(0), "settlement");
        pendingCash[msg.sender] = 0;
        totalSettled += cashOut;
        require(IERC20Like(cash).transfer(receiver, cashOut), "cash");
    }
}
