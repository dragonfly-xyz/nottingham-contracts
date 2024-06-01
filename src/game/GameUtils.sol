// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPlayer, PlayerBundle } from './IPlayer.sol';
import './Constants.sol';

error InvalidPlayerError();

/// @dev Extract a player's index from its address.
///      Because of the way players are deployed, the last 3 bits of a player's
///      address are also their index.
function getIndexFromPlayer(IPlayer player) pure returns (uint8 playerIdx) {
    require(player != IPlayer(address(0)), InvalidPlayerError());
    // The deployment process in the constructor ensures that the lowest 3 bits of the
    // player's address is also its player index.
    return uint8(uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK);
}

/// @dev Compute the hash of a player bundle for a round.
function getBundleHash(PlayerBundle memory bundle, uint16 round)
    pure returns (bytes32 hash)
{
    return bytes32((uint256(keccak256(abi.encode(bundle))) & ~uint256(0xFFFF)) | round);
}

/// @dev Extract the round index from a player bundle hash.
function getRoundFromBundleHash(bytes32 hash) pure returns (uint16 round) {
    return uint16(uint256(hash) & 0xFFFF);
}