// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TAGITCoreDemo
/// @notice Simplified demo contract for Arbitrum Open House NYC hackathon
/// @dev Stripped-down lifecycle contract with onlyAdmin access control
contract TAGITCoreDemo {
    enum State {
        NONE,
        MINTED,
        BOUND,
        ACTIVATED,
        CLAIMED,
        FLAGGED,
        RECYCLED
    }

    struct Asset {
        string name;
        State state;
        address owner;
        uint256 mintedAt;
        uint256 lastUpdated;
    }

    mapping(uint256 => Asset) public assets;
    uint256[] public tokenIds;
    address public admin;

    event AssetMinted(uint256 indexed tokenId, string name, address owner);
    event StateChanged(uint256 indexed tokenId, State oldState, State newState, address changedBy);

    error NotAdmin();
    error AlreadyExists();
    error DoesNotExist();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function mint(uint256 tokenId, string calldata name) external onlyAdmin {
        if (assets[tokenId].state != State.NONE) revert AlreadyExists();
        assets[tokenId] = Asset(name, State.MINTED, msg.sender, block.timestamp, block.timestamp);
        tokenIds.push(tokenId);
        emit AssetMinted(tokenId, name, msg.sender);
    }

    function changeState(uint256 tokenId, State newState) external onlyAdmin {
        Asset storage asset = assets[tokenId];
        if (asset.state == State.NONE) revert DoesNotExist();
        State oldState = asset.state;
        asset.state = newState;
        asset.lastUpdated = block.timestamp;
        emit StateChanged(tokenId, oldState, newState, msg.sender);
    }

    function getAsset(uint256 tokenId) external view returns (Asset memory) {
        return assets[tokenId];
    }

    function getTokenIds() external view returns (uint256[] memory) {
        return tokenIds;
    }

    function totalAssets() external view returns (uint256) {
        return tokenIds.length;
    }
}
