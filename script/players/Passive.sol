// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import '~/game/IGame.sol';

// Player that creates empty bundles and settles all players in order.
contract Passive is IPlayer {

    function createBundle(uint8 /* builderIdx */)
        external virtual returns (PlayerBundle memory bundle)
    {}

    function buildBlock(PlayerBundle[] calldata bundles)
        external virtual returns (uint256 goldBid)
    {
        // Settle all player bundles in player order.
        for (uint8 playerIdx; playerIdx < bundles.length; ++playerIdx) {
            IGame(msg.sender).settleBundle(playerIdx, bundles[playerIdx]);
        }
        // Bid the minimum.
        return 1;
    }
}
