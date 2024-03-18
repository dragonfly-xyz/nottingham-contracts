// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { IPlayer, PlayerBundle } from '~/game/Game.sol';

// Player bot that does nothing.
contract Noop is IPlayer {

    function createBundle(uint8 builderIdx)
        external returns (PlayerBundle memory bundle)
    {}

    function buildBlock(PlayerBundle[] calldata bundles)
        external returns (uint256 goldBid)
    { return 0; }
}
