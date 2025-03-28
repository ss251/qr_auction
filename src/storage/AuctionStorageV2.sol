// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AuctionTypesV2 } from "../types/AuctionTypesV2.sol";

/// @title AuctionStorageV2
/// @author S4rv4d
/// @notice The Auction storage contract for V2 with whitelist and QR token support
contract AuctionStorageV2 is AuctionTypesV2 {
    /// @notice The auction settings
    Settings public settings;

    /// @notice The state of the current auction
    Auction public auction;

    /// @notice The whitelist of authorized settlers
    WhitelistStorage internal _whitelist;
}