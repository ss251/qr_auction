// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

import { AuctionStorageV1 } from "./storage/AuctionStorageV1.sol";
import {IWETH} from "./interfaces/IWETH.sol";

contract QRAuction is Ownable, Pausable, ReentrancyGuard, AuctionStorageV1 {

    /// events -------------------------------.

    /// @notice Emitted when a bid is placed
    /// @param tokenId The Auction token id
    /// @param bidder The address of the bidder
    /// @param amount The amount of ETH
    /// @param extended If the bid extended the auction
    /// @param endTime The end time of the auction
    /// @param urlString bid url data
    event AuctionBid(uint256 tokenId, address bidder, uint256 amount, bool extended, uint256 endTime, string urlString);

    /// @notice Emitted when an auction is settled
    /// @param tokenId The Auction token id
    /// @param winner The address of the winning bidder
    /// @param amount The amount of ETH raised from the winning bid
    /// @param urlString bid url data
    event AuctionSettled(uint256 tokenId, address winner, uint256 amount, string urlString);

    /// @notice Emitted when an auction is created
    /// @param tokenId TThe Auction token id
    /// @param startTime The start time of the created auction
    /// @param endTime The end time of the created auction
    event AuctionCreated(uint256 tokenId, uint256 startTime, uint256 endTime);

    /// @notice Emitted when the auction duration is updated
    /// @param duration The new auction duration
    event DurationUpdated(uint256 duration);

    /// @notice Emitted when the reserve price is updated
    /// @param reservePrice The new reserve price
    event ReservePriceUpdated(uint256 reservePrice);

    /// @notice Emitted when the min bid increment percentage is updated
    /// @param minBidIncrementPercentage The new min bid increment percentage
    event MinBidIncrementPercentageUpdated(uint256 minBidIncrementPercentage);

    /// @notice Emitted when the time buffer is updated
    /// @param timeBuffer The new time buffer
    event TimeBufferUpdated(uint256 timeBuffer);

    /// errors --------------------------------.

    /// @dev Reverts if a bid is placed for the wrong token
    error INVALID_TOKEN_ID();

    /// @dev Reverts if a bid is placed for an auction thats over
    error AUCTION_OVER();

    /// @dev Reverts if a bid does not meet the reserve price
    error RESERVE_PRICE_NOT_MET();

    /// @dev Reverts if a bid is placed for an auction that hasn't started
    error AUCTION_NOT_STARTED();

    /// @dev Reverts if attempting to settle an active auction
    error AUCTION_ACTIVE();

    /// @dev Reverts if attempting to settle an auction that was already settled
    error AUCTION_SETTLED();

    /// @dev Reverts if a bid does not meet the minimum bid
    error MINIMUM_BID_NOT_MET();

    /// @dev Error for when the bid increment is set to 0.
    error MIN_BID_INCREMENT_1_PERCENT();

    /// @dev Reverts if the contract does not have enough ETH
    error INSOLVENT();

    /// @dev Thrown if the WETH contract throws a failure on transfer
    error FAILING_WETH_TRANSFER();

    /// @dev Thrown if the auction creation failed
    error AUCTION_CREATE_FAILED_TO_LAUNCH();

    /// @dev Thrown if a new auction cannot be created
    error CANNOT_CREATE_AUCTION();

    /// constants ----------------------------------.

    /// @notice The basis points for 100%
    uint256 private constant BPS_PER_100_PERCENT = 10_000;

    /// immutables ----------------------------------.

    /// @notice Iniital time buffer for auction bids
    uint40 private immutable INITIAL_TIME_BUFFER = 5 minutes;

    /// @notice Min bid increment BPS
    uint8 private immutable INITIAL_MIN_BID_INCREMENT_PERCENT = 10;

    /// @notice The address of WETH
    address private immutable WETH;

    /// constructor ------------------------------.
    constructor(
        address _weth, uint256 _duration, uint256 _reservePrice, address _treasury
    ) Ownable(msg.sender) {
        WETH = _weth;

        // Store the auction house settings
        settings.duration = SafeCast.toUint40(_duration);
        settings.reservePrice = _reservePrice;
        settings.treasury = _treasury;
        settings.timeBuffer = INITIAL_TIME_BUFFER;
        settings.minBidIncrement = INITIAL_MIN_BID_INCREMENT_PERCENT;
        _pause();
    }

    /// @dev Settles the current auction
    function _settleAuction() private {
        // Get a copy of the current auction
        Auction memory _auction = auction;

        // Ensure the auction wasn't already settled
        if (auction.settled) revert AUCTION_SETTLED();

        // Ensure the auction had started
        if (_auction.startTime == 0) revert AUCTION_NOT_STARTED();

        // Ensure the auction is over
        if (block.timestamp < _auction.endTime) revert AUCTION_ACTIVE();

        // Mark the auction as settled
        auction.settled = true;

        // If a bid was placed:
        if (_auction.highestBidder != address(0)) {
            // Cache the amount of the highest bid
            uint256 highestBid = _auction.highestBid;

            if (highestBid != 0) {
                // Deposit remaining amount to treasury
                _handleOutgoingTransfer(settings.treasury, highestBid);
            }

            settings.qrMetadata.validUntil = block.timestamp + settings.duration;
            settings.qrMetadata.urlString = _auction.qrMetadata.urlString;

        } else {
            // resort to default QR metadata
            settings.qrMetadata.validUntil = 0;
            settings.qrMetadata.urlString = "0x";
        }

        emit AuctionSettled(_auction.tokenId, _auction.highestBidder, _auction.highestBid, _auction.qrMetadata.urlString);
    }

    /// @dev Creates an auction for the next token
    function _createAuction() private returns (bool) {
        // Get the next token available for bidding
       // Store the token id
        auction.tokenId += 1;

        // Cache the current timestamp
        uint256 startTime = block.timestamp;

        // Used to store the auction end time
        uint256 endTime;

        // Cannot realistically overflow
        unchecked {
            // Compute the auction end time
            endTime = startTime + settings.duration;
        }

        // Store the auction start and end time
        auction.startTime = uint40(startTime);
        auction.endTime = uint40(endTime);

        // Reset data from the previous auction
        auction.highestBid = 0;
        auction.highestBidder = address(0);
        auction.settled = false;
        auction.qrMetadata.validUntil = endTime + settings.duration;
        auction.qrMetadata.urlString = "0x";

        emit AuctionCreated(auction.tokenId, startTime, endTime);
        return true;
    }

    function settleCurrentAndCreateNewAuction() external nonReentrant whenNotPaused {
        _settleAuction();
        _createAuction();
    }

    /// @notice Creates a bid for the current token
    /// @param _tokenId The token id for auction
    /// @param _urlString data to store
    function createBid(uint256 _tokenId, string memory _urlString) external payable nonReentrant {
        _createBid(_tokenId, _urlString);
    }

    /// @notice Creates a bid for the current token
    /// @param _tokenId The token id for auction
    function _createBid(uint256 _tokenId, string memory _urlString) private {
        // Ensure the bid is for the current token
        if (auction.tokenId != _tokenId) {
            revert INVALID_TOKEN_ID();
        }

        // Ensure the auction is still active
        if (block.timestamp >= auction.endTime) {
            revert AUCTION_OVER();
        }

        // Cache the amount of ETH attached
        uint256 msgValue = msg.value;

        // Cache the address of the highest bidder
        address lastHighestBidder = auction.highestBidder;

        // Cache the last highest bid
        uint256 lastHighestBid = auction.highestBid;

        // Store the new highest bid
        auction.highestBid = msgValue;

        // Store the new highest bidder
        auction.highestBidder = msg.sender;

        // update qr metadata
        auction.qrMetadata.validUntil = auction.endTime + settings.duration;
        auction.qrMetadata.urlString = _urlString;

        // Used to store whether to extend the auction
        bool extend;

        // Cannot underflow as `_auction.endTime` is ensured to be greater than the current time above
        unchecked {
            // Compute whether the time remaining is less than the buffer
            extend = (auction.endTime - block.timestamp) < settings.timeBuffer;

            // If the auction should be extended
            if (extend) {
                // Update the end time with the additional time buffer
                auction.endTime = uint40(block.timestamp + settings.timeBuffer);
            }
        }

        // If this is the first bid:
        if (lastHighestBidder == address(0)) {
            // Ensure the bid meets the reserve price
            if (msgValue < settings.reservePrice) {
                revert RESERVE_PRICE_NOT_MET();
            }

            // Else this is a subsequent bid:
        } else {
            // Used to store the minimum bid required
            uint256 minBid;

            // Cannot realistically overflow
            unchecked {
                // Compute the minimum bid
                minBid = lastHighestBid + ((lastHighestBid * settings.minBidIncrement) / 100);
            }

            // Ensure the incoming bid meets the minimum
            if (msgValue < minBid) {
                revert MINIMUM_BID_NOT_MET();
            }
            // Ensure that the second bid is not also zero
            if (minBid == 0 && msgValue == 0 && lastHighestBidder != address(0)) {
                revert MINIMUM_BID_NOT_MET();
            }

            // Refund the previous bidder
            _handleOutgoingTransfer(lastHighestBidder, lastHighestBid);
        }

        emit AuctionBid(_tokenId, msg.sender, msgValue, extend, auction.endTime, _urlString);
    }

    /// @notice Transfer ETH/WETH from the contract
    /// @param _to The recipient address
    /// @param _amount The amount transferring
    function _handleOutgoingTransfer(address _to, uint256 _amount) private {
        // Ensure the contract has enough ETH to transfer
        if (address(this).balance < _amount) revert INSOLVENT();

        // Used to store if the transfer succeeded
        bool success;

        assembly {
            // Transfer ETH to the recipient
            // Limit the call to 50,000 gas
            success := call(50000, _to, _amount, 0, 0, 0, 0)
        }

        // If the transfer failed:
        if (!success) {
            // Wrap as WETH
            IWETH(WETH).deposit{ value: _amount }();

            // Transfer WETH instead
            bool wethSuccess = IWETH(WETH).transfer(_to, _amount);

            // Ensure successful transfer
            if (!wethSuccess) {
                revert FAILING_WETH_TRANSFER();
            }
        }
    }

    ///                                                          ///
    ///                             PAUSE                        ///
    ///                                                          ///

    /// @notice Unpauses the auction house
    function unpause() external onlyOwner {
        _unpause();

        // If this is the first auction:
        if (!settings.launched) {
            // Mark the DAO as launched
            settings.launched = true;

            // Start the first auction
            if (!_createAuction()) {
                // In cause of failure, revert.
                revert AUCTION_CREATE_FAILED_TO_LAUNCH();
            }
        }
        // Else if the contract was paused and the previous auction was settled:
        else if (auction.settled) {
            // Start the next auction
            _createAuction();
        }
    }

    /// @notice Pauses the auction house
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Settles the latest auction when the contract is paused
    function settleAuction() external nonReentrant whenPaused {
        _settleAuction();
    }

    ///                                                          ///
    ///                       AUCTION SETTINGS                   ///
    ///                                                          ///

    /// @notice The DAO treasury
    function treasury() external view returns (address) {
        return settings.treasury;
    }

    /// @notice The time duration of each auction
    function duration() external view returns (uint256) {
        return settings.duration;
    }

    /// @notice The reserve price of each auction
    function reservePrice() external view returns (uint256) {
        return settings.reservePrice;
    }

    /// @notice The minimum amount of time to place a bid during an active auction
    function timeBuffer() external view returns (uint256) {
        return settings.timeBuffer;
    }

    /// @notice The minimum percentage an incoming bid must raise the highest bid
    function minBidIncrement() external view returns (uint256) {
        return settings.minBidIncrement;
    }

    ///                                                          ///
    ///                       UPDATE SETTINGS                    ///
    ///                                                          ///

    /// @notice Updates the time duration of each auction
    /// @param _duration The new time duration
    function setDuration(uint256 _duration) external onlyOwner whenPaused {
        settings.duration = SafeCast.toUint40(_duration);

        emit DurationUpdated(_duration);
    }

    /// @notice Updates the reserve price of each auction
    /// @param _reservePrice The new reserve price
    function setReservePrice(uint256 _reservePrice) external onlyOwner whenPaused {
        settings.reservePrice = _reservePrice;

        emit ReservePriceUpdated(_reservePrice);
    }

    /// @notice Updates the time buffer of each auction
    /// @param _timeBuffer The new time buffer
    function setTimeBuffer(uint256 _timeBuffer) external onlyOwner whenPaused {
        settings.timeBuffer = SafeCast.toUint40(_timeBuffer);

        emit TimeBufferUpdated(_timeBuffer);
    }

    /// @notice Updates the minimum bid increment of each subsequent bid
    /// @param _percentage The new percentage
    function setMinimumBidIncrement(uint256 _percentage) external onlyOwner whenPaused {
        if (_percentage == 0) {
            revert MIN_BID_INCREMENT_1_PERCENT();
        }

        settings.minBidIncrement = SafeCast.toUint8(_percentage);

        emit MinBidIncrementPercentageUpdated(_percentage);
    }
}