// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer } from '~/game/Game.sol';

// Player bot that does nothing.
contract Noop is IPlayer {

    function turn(uint8 /* builderIdx */) external pure {}

    function buildBlock() external pure returns (uint256 goldBid) {
        return 0;
    }
}
