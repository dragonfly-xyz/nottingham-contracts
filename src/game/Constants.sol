// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { IPlayer } from './IPlayer.sol';

IPlayer constant NULL_PLAYER = IPlayer(address(0));
uint160 constant PLAYER_ADDRESS_INDEX_MASK = 7;
uint8 constant GOLD_IDX = 0;
uint256 constant MIN_PLAYERS = 2;
// Bounded by size of address suffix.
uint256 constant MAX_PLAYERS = 8;
uint8 constant MAX_ROUNDS = 32;
uint256 constant MIN_WINNING_ASSET_BALANCE = 32e18;
uint256 constant MARKET_STARTING_GOLD_PER_PLAYER = 8e18;
uint256 constant MARKET_STARTING_GOODS_PER_PLAYER = 4e18;
uint8 constant INVALID_PLAYER_IDX = type(uint8).max;
uint256 constant MAX_CREATION_GAS = 200 * 0x8000 + 1e6;
uint256 constant PLAYER_CREATE_BUNDLE_GAS_BASE = 1e6;
uint256 constant PLAYER_CREATE_BUNDLE_GAS_PER_PLAYER = 250e3;
uint256 constant PLAYER_BUILD_BLOCK_GAS_BASE = 2e6;
uint256 constant PLAYER_BUILD_BLOCK_GAS_PER_PLAYER = 500e3;
uint256 constant MAX_RETURN_DATA_SIZE = 1024;
uint256 constant INCOME_AMOUNT = 1e18;
uint256 constant MIN_GAS_PER_BUNDLE_SWAP = 50e3;