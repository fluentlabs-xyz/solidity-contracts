// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IBridgeErrorCodes {
  /// @dev error thrown when the caller is not the bridge authority
  /// @dev functioins used: {sendMessage, receiveMessage, receiveFailedMessage}
  error OnlyBridgeAuthority();
  /// @dev error thrown when the caller is not the rollup authority
  /// @dev functioins used: {popSentMessage}
  error OnlyRollupAuthority();
  /// @dev error thrown when the rollup is not initialized
  error OnlyWhenRollupInited();
  /// @dev error thrown when the message has already been received
  error MessageAlreadyReceived();
  /// @dev error thrown when the message was received out of order
  error MessageReceivedOutOfOrder();
  error MessageNotFailed();
  error ForbiddenSelfCall();
  error ForbiddenReceiveRollbackedMessage();
  error ForbiddenRollbackReceivedMessage();
  error RollbackMessageMismatch();
  error InvalidBlockProof();
  error InvalidWithdrawalProof();
  error InvalidDestinationAddress();
  error ContractPaused();
}

interface IFluentBridge is IBridgeErrorCodes {
  event SentMessage(
    address indexed sender,
    address indexed to,
    uint256 value,
    bytes32 messageHash
  );

  event ReceivedMessage(bytes32 messageHash, bool successfulCall);

  // function sendMessage(address _to, bytes calldata _message) external payable;

  // function receiveMessage(
  //     address _from,
  //     address payable _to,
  //     uint256 _value,
  //     uint256 _nonce,
  //     bytes calldata _message
  // ) external payable;
}
