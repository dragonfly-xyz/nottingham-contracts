// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// A structure representing a sell order.
struct SwapSell {
    // Index of the asset to sell.
    uint8 fromAssetIdx;
    // Index of the asset to buy.
    uint8 toAssetIdx;
    // Amount of the asset to sell.
    uint256 fromAmount;
}

struct PlayerBundle {
    /// A sequence of swaps to carry out, in order.
    SwapSell[] swaps;
}

/// @notice Interface a player contract should implement.
interface IPlayer {
    // The implementing contract should also implement the following
    // constructor:
    // constructor(uint8 playerIdx, uint8 playerCount);

    /// @notice Create a bundle of swaps for the round. The current builder's player
    ///         index will be passed in.
    /// @dev This will be called for with each player as the builder, but state will
    ///      only persist for when `builderIdx` matches the builder that wins
    ///      the block auction. Thwe block builder must settle all bundles and
    ///      bundles are atomic. If this function reverts, it will be as if this player
    ///      returned an empty bundle.
    function createBundle(uint8 builderIdx)
        external returns (PlayerBundle memory bundle);
    
    /// @notice Build a block for the round, settling all bundles and returning the
    ///         bid (in gold).
    /// @dev This will be called for each player, but state will only persist for
    ///      the player that wins the block auction.
    ///      If this function reverts, another player's bundle is not settled, or
    ///      this player does not have enough gold to cover the bid after it returns,
    ///      this block and bid will be ignored, letting the next highest bidder
    ///      win the block auction.
    function buildBlock(PlayerBundle[] calldata bundles)
        external returns (uint256 goldBid);
}