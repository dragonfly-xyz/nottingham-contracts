// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

contract Contest {
    struct Confirmation {
        uint256 expiry;
        uint256 nonce;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    error OnlyHostError();

    event PlayerRegistered(address indexed player);
    event PlayerCode(bytes encryptedCode);

    address public immutable RETIRER;
    address payable public immutable HOST;
    address public immutable NOTARY;

    mapping (uint256 seasonIdx => bytes32 privKey) seasonPrivKey;
    mapping (uint256 seasonIdx => bytes32 pubKey) seasonPubKey;

    constructor(address payable host, address notary) {
        HOST = host;
        NOTARY = notary;
    }

    modifier onlyHost {
        if (msg.sender != HOST) revert OnlyHostError();
        _;
    }

    modifier onlyRetirer {
        if (msg.sender != RETIRER) revert OnlyHostError();
        _;
    }
    
    function retire(address player) external onlyRetirer {}
    function register(Confirmation memory confirmation) external {}
    function setPlayerCode(uint256 seasonIdx, bytes memory encryptedCode) external {}
    function rate(
        uint256 seasonIdx,
        address[] memory players,
        int64[] memory mus,
        int64[] memory sigmas,
        uint32[] memory winCounts,
        uint32[] memory matchCounts
    ) external onlyHost {}
    function newSeason(uint256 seasonIdx, bytes32 seasonPubKey_) external onlyHost {}
    function claim(address payable recipient) external {}
    function endSeason(uint256 seasonIdx, bytes32 seasonPrivKey_) external onlyHost {}
    function getRandao() external view returns (uint256) {}
    function getPlayerRating(uint256 seasonIdx, address player) external view returns (int64 mu, int64 sigma) {}
    function getPlayerCodeHash(uint256 seasonIdx, address player) external view returns (bytes32 codeHash) {}
    function getSeason() external view returns (uint256) {}
    function jiggle(bytes32 entropy) external {}
}