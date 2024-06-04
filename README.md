# Searchers of Nottingham

Searchers of Nottingham is an [MEV](https://chain.link/education-hub/maximal-extractable-value-mev)-themed game built on the [Ethereum](https://ethereum.org) Virtual Machine. Players submit compiled smart contracts which represent Merchants at a medieval fair trying to stock their stall with goods (tokens). Merchants face each other in multiple small games. Each round Merchants will try to exchange their gold and goods at the Market (a constant product [AMM](https://chain.link/education-hub/what-is-an-automated-market-maker-amm)). But a Merchant can also choose to bid gold to become the "Sheriff" for that round. The Sheriff chooses the order in which all trades are made and can also make their own trades at will. The first Merchant to acquire the maximum amount of any single good will win!

## Game Concepts


## Project Setup
Assuming you already have [foundry](https://getfoundry.sh) configured, clone the repo and enter the project folder, then just

```bash
# Install dependencies.
forge install
# Build the project.
forge build
```

You can find the core logic for the game inside [Game.sol](./src/game/Game.sol).

## Developing Players

## Local Matches
The project comes with a foundry [script](./script/Match.sol) for running matches locally so you can see how well your bot performs against others. Matches can be held against 2 or more player contracts.

For example, you can run a match against the included example players [`GreedyBuyer`](./script/players/GreedyBuyer.sol) and [`CheapBuyer`](./scripts/players/CheapBuyer.sol) with the following command:

```bash
forge script Match --sig 'runMatch(string[])' '["GreedyBuyer.sol", "CheapBuyer.sol"]'
```

Note that `runMatch()` assigns players the same player indexes, which is analagous to turn order, as they are passed in. The performance of some of the example players can be biased by their order in a match. You can instead use `runShuffledMatch()` to assign players a random index beforehand:

```bash
forge script Match --sig 'runShuffledMatch(string[])' '["GreedyBuyer.sol", "CheapBuyer.sol"]'
```

If successful, the output of either command will:
- After each round, print the asset balances of each player (sorted by max non-gold balance).
    - The player that built the block will be prefixed with `(B)`.
- At the end of game, print the final score (max non-gold balance) for each player.

The square brackets after each player name indicates their assigned player index. The emoji and parenthesis after assets indicate their asset index.

```bash
  Round 1:
  	   CheapBuyer [1]:
  		0.0 🪙, 0.0 🍅, 0.9295 🥖
  	(B) CheapFrontRunner [0]:
  		0.0 🪙, 0.237 🍅, 0.9285 🥖
  	   GreedyBuyer [2]:
  		0.0 🪙, 0.0 🍅, 0.8885 🥖
# ...
  Round 32:
  	(B) CheapFrontRunner [0]:
  		0.0 🪙, 30.6200 🍅, 0.7229 🥖
  	   GreedyBuyer [2]:
  		0.0 🪙, 0.0 🍅, 29.4251 🥖
  	   CheapBuyer [1]:
  		0.0 🪙, 1.9145 🍅, 0.0 🥖
  🏁 Game ended after 32 rounds:
  	🏆️ CheapFrontRunner [0]: 30.6200 🍅 (1)
  	🥈 GreedyBuyer [2]: 29.4251 🥖 (2)
  	🥉 CheapBuyer [1]: 1.9145 🍅 (1)

```

If you want to see more detail of what went on during a match, you can run the script with full traces on by passing in the `-vvvv` flag. Be warned, this will be a lot of output and can be difficult to read because of how the game logic calls player callbacks repeatedly to simulate them.