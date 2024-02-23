// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IPlayer {
    // constructor(uint8 playerIdx, uint8 playerCount);
    function turn(uint8 builderIdx) external;
    function buildBlock() external returns (uint256 goldBid);
}