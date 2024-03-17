// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

struct SwapSell {
    uint8 fromAssetIdx;
    uint8 toAssetIdx;
    uint256 fromAmount;
    uint256 minToAmount;
}

struct PlayerBundle {
    SwapSell[] swaps;
    uint256 builderGoldTip;
}

interface IPlayer {
    // constructor(uint8 playerIdx, uint8 playerCount);
    function createBundle(uint8 builderIdx) external returns (PlayerBundle memory bundle);
    function buildBlock(PlayerBundle[] calldata bundles) external returns (uint256 goldBid);
}