// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { IPlayer, PlayerBundle } from '~/game/Game.sol';

// Player that does nothing.
contract Noop is IPlayer {

    function createBundle(uint8 /* builderIdx */)
        external virtual returns (PlayerBundle memory bundle)
    {}

    function buildBlock(PlayerBundle[] calldata /* bundles */)
        external virtual returns (uint256 goldBid)
    { /* Do nothing. Equivalent of no bid. */ }
}
