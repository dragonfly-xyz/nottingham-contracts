// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import './CheapBuyer.sol';

// Player that tries to buy whichever good is the cheapest
// AND tries to perform its swaps before everyone else.
contract CheapFrontRunner is CheapBuyer {

    constructor(IGame game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
        CheapBuyer(game, playerIdx, playerCount, assetCount) {}

    function createBundle(uint8 /* builderIdx */)
        external virtual override returns (PlayerBundle memory bundle)
    {
        uint8 wantAssetIdx = _getMaxBuyableGood();
        bundle.swaps = new SwapSell[](MAX_SWAPS_PER_BUNDLE);
        // Convert 99% of every other asset to the target asset and
        // the remaining 1% to gold.
        uint256 n;
        for (uint8 assetIdx; assetIdx < ASSET_COUNT; ++assetIdx) {
            if (assetIdx != wantAssetIdx && assetIdx != GOLD_IDX) {
                uint256 bal = GAME.balanceOf(PLAYER_IDX, assetIdx);
                bundle.swaps[n++] = SwapSell({
                    fromAssetIdx: assetIdx,
                    toAssetIdx: wantAssetIdx,
                    fromAmount: bal * 99 / 100
                });
                bundle.swaps[n++] = SwapSell({
                    fromAssetIdx: assetIdx,
                    toAssetIdx: GOLD_IDX,
                    fromAmount: bal * 1 / 100
                });
            }
        }
    }

    function buildBlock(PlayerBundle[] memory bundles)
        external virtual override returns (uint256 goldBid)
    {
        // Buy whatever asset we can get the most of.
        uint8 wantAssetIdx = _getMaxBuyableGood();

        // Sell 5% of all the other goods for gold and the
        // remaining for the asset we want.
        uint256 goldBought;
        for (uint8 i; i < GOODS_COUNT; ++i) {
            uint8 assetIdx = FIRST_GOOD_IDX + i;
            if (assetIdx != wantAssetIdx) {
                goldBought += GAME.sell(
                    assetIdx,
                    GOLD_IDX,
                    GAME.balanceOf(PLAYER_IDX, assetIdx) * 5 / 100
                );
                GAME.sell(
                    assetIdx,
                    wantAssetIdx,
                    GAME.balanceOf(PLAYER_IDX, assetIdx) * 95 / 100
                );
            }
        }

        // Settle everyone else's bundles.
        for (uint8 playerIdx = 0; playerIdx < bundles.length; ++playerIdx) {
            if (playerIdx == PLAYER_IDX) {
                // Skip our bundle.
                continue;
            }
            GAME.settleBundle(playerIdx, bundles[playerIdx]);
        }
        // Bid the gold we bought.
        return goldBought;
    }
}
