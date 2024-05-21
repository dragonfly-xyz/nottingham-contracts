// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, PlayerBundle } from '~/game/Game.sol';

// Player that creates empty bundles and settles all players in order.
contract Passive is IPlayer {

    function createBundle(uint8 /* builderIdx */)
        external virtual returns (PlayerBundle memory bundle)
    {}

    function buildBlock(PlayerBundle[] calldata bundles)
        external virtual returns (uint256 goldBid)
    {
        for (uint8 playerIdx; playerIdx < bundles.length; ++playerIdx) {
            Game(msg.sender).settleBundle(playerIdx, bundles[playerIdx]);
        }
        // Bid the minimum.
        return 1;
    }
}
