// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AuctionTypesV2
/// @author S4rv4d
/// @notice The Auction custom data types for V2
contract AuctionTypesV2 {

    struct QRData {
        uint256 validUntil;
        string urlString;
    }

    /// @notice The settings type
    /// @param treasury The DAO treasury
    /// @param duration The time duration of each auction
    /// @param timeBuffer The minimum time to place a bid
    /// @param minBidIncrement The minimum percentage an incoming bid must raise the highest bid
    /// @param launched If the first auction has been kicked off
    /// @param reservePrice The reserve price of each auction
    /// @param qrToken The address of the QR token
    struct Settings {
        address treasury;
        uint40 duration;
        uint40 timeBuffer;
        uint8 minBidIncrement;
        uint256 reservePrice;
        bool launched;
        QRData qrMetadata;
        address qrToken;
    }

    /// @notice The auction type
    /// @param tokenId auction id to reference
    /// @param highestBid The highest amount of QR tokens raised
    /// @param highestBidder The leading bidder
    /// @param startTime The timestamp the auction starts
    /// @param endTime The timestamp the auction ends
    /// @param settled If the auction has been settled
    struct Auction {
        uint256 tokenId;
        uint256 highestBid;
        address highestBidder;
        uint40 startTime;
        uint40 endTime;
        bool settled;
        QRData qrMetadata;
    }

    /// @notice The whitelist type to store authorized settlers
    /// @param settlers A mapping of addresses to their settler status
    struct WhitelistStorage {
        mapping(address => bool) settlers;
    }
}