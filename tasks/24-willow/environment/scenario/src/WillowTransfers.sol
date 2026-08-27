// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IWillowCheckpointTarget {
    function checkpointFromController(address account, uint256 balanceBefore) external;
}

interface IWillowMemberVault {
    function approve(address spender, uint256 amount) external returns (bool);
    function claimAll(address receiver) external returns (uint256[] memory rewards);
    function withdraw(uint256 shares, address receiver) external returns (uint256 assets);
}

library WillowEligibility {
    function code(uint256 index) internal pure returns (uint80 value) {
        uint256 entropy = uint256(keccak256(abi.encode("Willow eligibility", index)));
        value = uint80(uint16(1_000 + entropy % 49_001));
        value |= uint80(uint16(1_000 + (entropy >> 48) % 49_001)) << 16;
        value |= uint80(uint16(1_000 + (entropy >> 96) % 49_001)) << 32;
        value |= uint80(uint16(1_000 + (entropy >> 144) % 49_001)) << 48;
    }
}

contract WillowMemberAccount {
    address public operator;
    address public vault;

    function initialize(address operator_, address vault_) external {
        require(operator == address(0) && operator_ != address(0) && vault_ != address(0), "initialized");
        operator = operator_;
        vault = vault_;
        IWillowMemberVault(vault_).approve(operator_, type(uint256).max);
    }

    function register(address membership, uint256 index, uint80 code, bytes32[] calldata proof) external {
        require(msg.sender == operator, "operator");
        WillowMembership(membership).register(index, code, proof);
    }

    function claim(address receiver) external {
        require(msg.sender == operator, "operator");
        IWillowMemberVault(vault).claimAll(receiver);
    }

    function exit(uint256 shares, address receiver) external {
        require(msg.sender == operator, "operator");
        IWillowMemberVault(vault).withdraw(shares, receiver);
    }
}

contract WillowAccountFactory {
    event AccountCreated(address indexed account, uint256 indexed salt);

    function deploy(uint256 salt, address operator, address vault) external returns (address account) {
        account = address(new WillowMemberAccount{salt: bytes32(salt)}());
        WillowMemberAccount(account).initialize(operator, vault);
        emit AccountCreated(account, salt);
    }

    function compute(uint256 salt) public view returns (address) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), bytes32(salt), keccak256(type(WillowMemberAccount).creationCode)
            )
        );
        return address(uint160(uint256(digest)));
    }
}

contract WillowMembership {
    bytes32 public immutable root;
    uint8 public immutable requiredMembers;
    uint256 public immutable requiredRiskA;
    uint256 public immutable requiredRiskB;
    uint256 public immutable requiredRiskC;
    uint256 public immutable requiredRiskD;
    mapping(address => bool) public member;
    mapping(address => uint80) public memberCode;
    mapping(address => uint8) public cohortCount;
    mapping(address => uint256) public cohortRiskA;
    mapping(address => uint256) public cohortRiskB;
    mapping(address => uint256) public cohortRiskC;
    mapping(address => uint256) public cohortRiskD;

    constructor(bytes32 root_, uint8 count, uint256 riskA, uint256 riskB, uint256 riskC, uint256 riskD) {
        require(root_ != bytes32(0) && count != 0 && riskA != 0 && riskB != 0 && riskC != 0 && riskD != 0, "root");
        root = root_;
        requiredMembers = count;
        requiredRiskA = riskA;
        requiredRiskB = riskB;
        requiredRiskC = riskC;
        requiredRiskD = riskD;
    }

    function eligibilityCode(uint256 index) external pure returns (uint80) {
        return WillowEligibility.code(index);
    }

    function register(uint256 index, uint80 code, bytes32[] calldata proof) external {
        require(index < 256 && !member[msg.sender] && code == WillowEligibility.code(index), "registration");
        bytes32 node = keccak256(abi.encodePacked(msg.sender, code));
        for (uint256 i; i < proof.length; ++i) {
            node = index & 1 == 0
                ? keccak256(abi.encodePacked(node, proof[i]))
                : keccak256(abi.encodePacked(proof[i], node));
            index >>= 1;
        }
        require(node == root && index == 0, "proof");
        member[msg.sender] = true;
        memberCode[msg.sender] = code;
        address cohort = WillowMemberAccount(msg.sender).operator();
        require(cohortCount[cohort] < requiredMembers, "cohort full");
        ++cohortCount[cohort];
        cohortRiskA[cohort] += uint16(code);
        cohortRiskB[cohort] += uint16(code >> 16);
        cohortRiskC[cohort] += uint16(code >> 32);
        cohortRiskD[cohort] += uint16(code >> 48);
    }

    function cohortCleared(address cohort) external view returns (bool) {
        return cohortCount[cohort] == requiredMembers && cohortRiskA[cohort] == requiredRiskA
            && cohortRiskB[cohort] == requiredRiskB && cohortRiskC[cohort] == requiredRiskC
            && cohortRiskD[cohort] == requiredRiskD;
    }
}

contract WillowTransferController {
    address public administrator = msg.sender;
    address public immutable vault;
    address public immutable membership;
    mapping(bytes4 => uint8) public movementMode;

    event GatewayRegistered(address indexed gateway);

    constructor(address vault_, address membership_) {
        vault = vault_;
        membership = membership_;
        movementMode[bytes4(keccak256("transfer(address,uint256)"))] = 3;
        movementMode[bytes4(keccak256("transferFrom(address,address,uint256)"))] = 1;
    }

    function registerGateway(address gateway) external {
        require(msg.sender == administrator && gateway != address(0), "administrator");
        administrator = address(0);
        emit GatewayRegistered(gateway);
    }

    function beforeMove(
        address owner,
        address receiver,
        uint256 ownerBalance,
        uint256 receiverBalance,
        bytes4 entrypoint
    ) external {
        require(msg.sender == vault, "vault");
        uint8 mode = movementMode[entrypoint];
        require(mode != 0, "entrypoint");
        if (receiverBalance == 0) require(WillowMembership(membership).member(receiver), "membership");
        if (mode & 1 != 0) IWillowCheckpointTarget(vault).checkpointFromController(owner, ownerBalance);
        if (mode & 2 != 0) {
            IWillowCheckpointTarget(vault).checkpointFromController(receiver, receiverBalance);
        }
    }

    function rewardEligible(address account) external view returns (bool) {
        return WillowMembership(membership).member(account)
            && WillowMembership(membership).cohortCleared(WillowMemberAccount(account).operator());
    }

    function rewardBps(address account) external view returns (uint256) {
        uint80 code = WillowMembership(membership).memberCode(account);
        require(code != 0, "membership");
        return 8_500 + uint16(code) % 1_501;
    }
}
