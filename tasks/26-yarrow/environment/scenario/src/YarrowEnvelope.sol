// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library YarrowEnvelopeCodec {
    bytes4 internal constant MAGIC = 0x59415257; // "YARW"
    uint8 internal constant VERSION = 3;

    struct Message {
        uint32 sourceDomain;
        uint32 destinationDomain;
        uint64 nonce;
        address claimedTransport;
        bytes sourceAddress;
        bytes32 commandId;
        bytes32 accountId;
        bytes payload;
    }

    function decode(bytes calldata envelope) internal pure returns (Message memory message) {
        // Fixed prefix through sourceAddressLength.
        require(envelope.length >= 43 + 32 + 32 + 4 + 32, "short envelope");
        require(_bytes4(envelope, 0) == MAGIC && uint8(envelope[4]) == VERSION, "format");

        message.sourceDomain = _uint32(envelope, 5);
        message.destinationDomain = _uint32(envelope, 9);
        message.nonce = _uint64(envelope, 13);
        message.claimedTransport = _address(envelope, 21);

        uint256 sourceLength = _uint16(envelope, 41);
        uint256 cursor = 43;
        require(sourceLength != 0 && cursor + sourceLength + 100 <= envelope.length, "source");
        message.sourceAddress = envelope[cursor:cursor + sourceLength];
        cursor += sourceLength;

        message.commandId = _bytes32(envelope, cursor);
        cursor += 32;
        message.accountId = _bytes32(envelope, cursor);
        cursor += 32;
        uint256 payloadLength = _uint32(envelope, cursor);
        cursor += 4;
        require(payloadLength != 0 && cursor + payloadLength + 32 == envelope.length, "payload");
        message.payload = envelope[cursor:cursor + payloadLength];
        bytes32 suppliedChecksum = _bytes32(envelope, cursor + payloadLength);
        require(suppliedChecksum == keccak256(envelope[:cursor + payloadLength]), "checksum");
    }

    function _bytes4(bytes calldata data, uint256 offset) private pure returns (bytes4 value) {
        assembly {
            value := calldataload(add(data.offset, offset))
        }
    }

    function _bytes32(bytes calldata data, uint256 offset) private pure returns (bytes32 value) {
        assembly {
            value := calldataload(add(data.offset, offset))
        }
    }

    function _address(bytes calldata data, uint256 offset) private pure returns (address value) {
        assembly {
            value := shr(96, calldataload(add(data.offset, offset)))
        }
    }

    function _uint16(bytes calldata data, uint256 offset) private pure returns (uint16 value) {
        assembly {
            value := shr(240, calldataload(add(data.offset, offset)))
        }
    }

    function _uint32(bytes calldata data, uint256 offset) private pure returns (uint32 value) {
        assembly {
            value := shr(224, calldataload(add(data.offset, offset)))
        }
    }

    function _uint64(bytes calldata data, uint256 offset) private pure returns (uint64 value) {
        assembly {
            value := shr(192, calldataload(add(data.offset, offset)))
        }
    }
}

contract YarrowEnvelopeVerifier {
    address public administrator = msg.sender;
    address public trustedTransport;
    uint32 public sourceDomain;
    uint32 public destinationDomain;
    bytes public sourceAddress;
    bytes32 public sourceAddressHash;

    event TransportConfigured(address indexed transport, uint32 indexed source, uint32 indexed destination);

    function configure(address transport, uint32 source, uint32 destination, bytes calldata sourceName) external {
        require(msg.sender == administrator && trustedTransport == address(0), "configuration");
        require(transport != address(0) && source != destination && sourceName.length >= 12, "transport");
        trustedTransport = transport;
        sourceDomain = source;
        destinationDomain = destination;
        sourceAddress = sourceName;
        sourceAddressHash = keccak256(sourceName);
        administrator = address(0);
        emit TransportConfigured(transport, source, destination);
    }

    function verify(bytes calldata envelope) external view returns (YarrowEnvelopeCodec.Message memory message) {
        message = YarrowEnvelopeCodec.decode(envelope);
        require(
            message.sourceDomain == sourceDomain && message.destinationDomain == destinationDomain
                && message.claimedTransport == trustedTransport
                && keccak256(message.sourceAddress) == sourceAddressHash,
            "origin"
        );
        require(message.nonce != 0 && message.commandId != bytes32(0) && message.accountId != bytes32(0), "message");
    }
}
