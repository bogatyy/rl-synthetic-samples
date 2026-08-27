// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./YarrowEnvelope.sol";
import "./YarrowCustody.sol";

contract YarrowBridgeRouter {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public messageVerifier;
    address public accountRouter;
    bytes32 public custodyAccountId;
    mapping(bytes32 => bool) public completed;
    mapping(uint64 => bytes32) public commandAtNonce;

    event CommandDelivered(bytes32 indexed commandId, bytes32 indexed accountId, uint64 nonce);

    function configure(
        address asset,
        address reserve,
        address verifier,
        address accounts,
        bytes32 accountId
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        require(asset != address(0) && reserve != address(0) && verifier != address(0) && accounts != address(0), "address");
        settlementAsset = asset;
        protectedReserve = reserve;
        messageVerifier = verifier;
        accountRouter = accounts;
        custodyAccountId = accountId;
        administrator = address(0);
    }

    function expressExecute(bytes calldata envelope) external {
        YarrowEnvelopeCodec.Message memory message = YarrowEnvelopeVerifier(messageVerifier).verify(envelope);
        require(message.accountId == custodyAccountId, "account");
        require(!completed[message.commandId] && commandAtNonce[message.nonce] == bytes32(0), "replay");
        completed[message.commandId] = true;
        commandAtNonce[message.nonce] = message.commandId;
        YarrowAccountRouter(accountRouter).dispatch(message.accountId, message.commandId, message.payload);
        emit CommandDelivered(message.commandId, message.accountId, message.nonce);
    }
}
