// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AuctionTypesV1 } from "../types/AuctionTypesV1.sol";

/// @title AuctionStorageV1
/// @author S4rv4d
/// @notice modified version of the The Auction storage contract by nouns builder (zora) 
contract AuctionStorageV1 is AuctionTypesV1 {
    /// @notice The auction settings
    Settings public settings;

    /// @notice The state of the current auction
    Auction public auction;
}