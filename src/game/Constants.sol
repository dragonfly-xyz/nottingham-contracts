// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { IPlayer } from './IPlayer.sol';

IPlayer constant NULL_PLAYER = IPlayer(address(0));
uint160 constant PLAYER_ADDRESS_INDEX_MASK = 7;
// Asset index of the gold asset/token.
uint8 constant GOLD_IDX = 0;
uint8 constant FIRST_GOOD_IDX = 1;
uint256 constant MIN_PLAYERS = 2;
// Bounded by size of address suffix.
uint256 constant MAX_PLAYERS = 8;
// Max number of rounds before game over.
uint8 constant MAX_ROUNDS = 32;
// First player to reach this amount of any non-gold asset before
// `MAX_ROUNDS` rounds wins the game.
uint256 constant MIN_WINNING_ASSET_BALANCE = 64e18;
// How much gold the market starts with at the beginning of the game,
// to be multiplied with the number of players.
uint256 constant MARKET_STARTING_GOLD_PER_PLAYER = 1e18;
// How much of every good the market starts with at the beginning of the game,
// to be multiplied with the number of players.
uint256 constant MARKET_STARTING_GOODS_PER_PLAYER = 8e18;
uint8 constant INVALID_PLAYER_IDX = type(uint8).max;
uint256 constant MAX_CREATION_GAS = 200 * 0x8000 + 1e6;
uint256 constant PLAYER_CREATE_BUNDLE_GAS_BASE = 1e6;
uint256 constant PLAYER_CREATE_BUNDLE_GAS_PER_PLAYER = 250e3;
uint256 constant PLAYER_BUILD_BLOCK_GAS_BASE = 2e6;
uint256 constant PLAYER_BUILD_BLOCK_GAS_PER_PLAYER = 500e3;
uint256 constant MAX_RETURN_DATA_SIZE = 1024;
uint256 constant MIN_GAS_PER_BUNDLE_SWAP = 10e3;
// How much gold each player gets at the start of each round.
uint256 constant GOLD_INCOME_AMOUNT = 1;
// How much of every goods each player gets at the start of each round.
uint256 constant GOODS_INCOME_AMOUNT = 1e18;