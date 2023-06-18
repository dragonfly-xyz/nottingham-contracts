// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

After 10 complete rotations, winner:
    - End up with most ETH.
        - Remaining product is dumped on market price.
            - What order? Market gets forked per player?

Bonuses for selling more of a thing?

Start of round:
    1. Rotate sheriff.
    2. +10 product to every merchant.
    3. Player to right of sheriff submits actions, and so on.

Gas price?
    - Increase with turns?
Deck building mechanics? Build up resources early on?
Need a cost to MEV or anti-MEV.
Actions (in any order or count):
    - 
interface IProduct {
    function name() external view returns (string memory);
    function balanceOf(owner) external view returns (uint256);
    function sellTo(buyer, sellAmount) external returns (uint256 buyAmount);
    function sell(sellAmount) external returns (uint256 buyAmount);
    function borrow(lender, borrowAmount, callbackSelector) external returns (uint256 fee);
    function deposit(depositAmount) external returns (uint256 yield);
    function withdraw(withdrawAmount) external returns (uint256 yield);
    function rates() external view returns (uint256 borrowRate, uint256 depositRate);
}

interface IBuyer {
    function sell(uint256 sellAmount) external returns (uint256 gold);
}

interface ISeller {
    function buy() external payable returns (uint256 gold);
}

interface IMerchant is IBuyer, ISeller {
    function product() external view returns (IProduct);
    function borrow(uint256 borrowAmount, callback) external view returns (uint256 fee);
}

interface ISheriff {
    function prepare(block) external;
}

interface IBlock {
    // Submit a tx. Stores them sorted by bribe.
    function submit(bytes callbackData, uint256 gasLimit) external payable returns (uint256 idx);
    // Gets the number of submitted txs. Only callable by the sheriff.
    function length() external view returns (uint256);
    // Get a submitted tx. Only callable by the sheriff.
    function peek(uint256 idx) external view returns (QueuedAction);
    // Queue a submitted tx to be included. Only callable by the sheriff.
    // This is weird because sheriff gets bribe instantly...
    function commit(uint256 idx) external;
    // Queue an unsubmitted tx to be included. Only callable by the sheriff.
    function commit(bytes callbackData, uint256 gasLimit) external;
    // Execute the committed block and claim bribes.
    function seal() external returns (uint256 totalBribe);
    // Simulate any tx.
    function simulate(QueuedAction action, callbackSelector) external (bytes memory result);
}

contract PendingPool {
    function submit(QueuedAction calldata action) external;
    function bundle(QueuedAction[] calldata actions) external;
}

struct QueuedAction {
    address from;
    bytes callbackData;
    uint256 gasLimit;
    uint256 bribe;
}

contract ExpTest is Test {
    function setUp() external {
    }

    function testFoo() external {
    }
}
