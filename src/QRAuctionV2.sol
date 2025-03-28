// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {AuctionStorageV2} from "./storage/AuctionStorageV2.sol";
import {IWETH} from "./interfaces/IWETH.sol";

contract QRAuctionV2 is Ownable, Pausable, ReentrancyGuard, AuctionStorageV2 {

    /// events -------------------------------.

    /// @notice Emitted when a bid is placed
    /// @param tokenId The Auction token id
    /// @param bidder The address of the bidder
    /// @param amount The amount of QR tokens
    /// @param extended If the bid extended the auction
    /// @param endTime The end time of the auction
    /// @param urlString bid url data
    event AuctionBid(uint256 tokenId, address bidder, uint256 amount, bool extended, uint256 endTime, string urlString);

    /// @notice Emitted when an auction is settled
    /// @param tokenId The Auction token id
    /// @param winner The address of the winning bidder
    /// @param amount The amount of QR tokens raised from the winning bid
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

    /// @notice Emitted when a refund fails
    /// @param to The address that should receive the refund
    /// @param amount The amount of QR tokens that failed to transfer
    /// @param reason Why the refund failed
    event RefundFailed(address indexed to, uint256 amount, string reason);

    /// @notice Emitted when a settler is added or removed from the whitelist
    /// @param settler The address of the settler
    /// @param status Whether the settler is added or removed
    event SettlerWhitelistUpdated(address indexed settler, bool status);

    /// @notice Emitted when an admin manually overrides the auction winner
    /// @param tokenId The token ID of the auction
    /// @param originalWinner The original winning bidder
    /// @param newWinner The new winning bidder
    /// @param amount The bid amount
    /// @param refunded Whether the original winner was refunded
    event AuctionWinnerOverridden(uint256 tokenId, address originalWinner, address newWinner, uint256 amount, bool refunded);

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

    /// @dev Reverts if the contract does not have enough QR tokens
    error INSOLVENT();

    /// @dev Thrown if the QR token transfer fails
    error QR_TOKEN_TRANSFER_FAILED();

    /// @dev Thrown if the auction creation failed
    error AUCTION_CREATE_FAILED_TO_LAUNCH();

    /// @dev Thrown if a new auction cannot be created
    error CANNOT_CREATE_AUCTION();

    /// @dev Thrown if the caller is not in the settler whitelist
    error NOT_WHITELISTED_SETTLER();

    /// @dev Thrown if the bidder to promote isn't part of the current auction
    error INVALID_BIDDER_TO_PROMOTE();

    /// constants ----------------------------------.

    /// @notice The basis points for 100%
    uint256 private constant BPS_PER_100_PERCENT = 10_000;

    /// immutables ----------------------------------.

    /// @notice Iniital time buffer for auction bids
    uint40 private immutable INITIAL_TIME_BUFFER = 5 minutes;

    /// @notice Min bid increment BPS
    uint8 private immutable INITIAL_MIN_BID_INCREMENT_PERCENT = 10;

    /// constructor ------------------------------.
    constructor(
        address _qrToken, uint256 _duration, uint256 _reservePrice, address _treasury
    ) Ownable(msg.sender) {
        settings.qrToken = _qrToken;

        // Store the auction house settings
        settings.duration = SafeCast.toUint40(_duration);
        settings.reservePrice = _reservePrice;
        settings.treasury = _treasury;
        settings.timeBuffer = INITIAL_TIME_BUFFER;
        settings.minBidIncrement = INITIAL_MIN_BID_INCREMENT_PERCENT;
        
        // Add owner to whitelist by default
        _whitelist.settlers[msg.sender] = true;
        emit SettlerWhitelistUpdated(msg.sender, true);
        
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
                // Check if enough tokens before transfer
                IERC20 qrTokenContract = IERC20(settings.qrToken);
                uint256 balance = qrTokenContract.balanceOf(address(this));
                if (balance >= highestBid) {
                    _handleTreasuryTransfer(highestBid);
                }
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

    /// @notice Settles the current auction and creates a new one
    /// @dev Only whitelisted settlers can call this function
    function settleCurrentAndCreateNewAuction() external nonReentrant whenNotPaused {
        // Check if caller is in whitelist
        if (!_whitelist.settlers[msg.sender]) revert NOT_WHITELISTED_SETTLER();
        
        _settleAuction();
        _createAuction();
    }

    /// @notice Creates a bid for the current token
    /// @param _tokenId The token id for auction
    /// @param _urlString data to store
    function createBid(uint256 _tokenId, string memory _urlString) external nonReentrant {
        if (auction.tokenId != _tokenId) revert INVALID_TOKEN_ID();
        if (auction.settled) revert AUCTION_SETTLED();

        address lastHighestBidder = auction.highestBidder;
        uint256 lastHighestBid = auction.highestBid;
        uint256 bidAmount = 0;

        // Check the allowance and balance
        IERC20 qrTokenContract = IERC20(settings.qrToken);
        uint256 allowance = qrTokenContract.allowance(msg.sender, address(this));
        uint256 balance = qrTokenContract.balanceOf(msg.sender);

        // The bid amount is the minimum of allowance and balance
        bidAmount = allowance < balance ? allowance : balance;

        // Check if the bid meets the requirements
        if (lastHighestBidder == address(0)) {
            // First bid must meet reserve price
            if (bidAmount < settings.reservePrice) revert RESERVE_PRICE_NOT_MET();
        } else {
            // Subsequent bids must meet minimum increment
            uint256 minBid;
            unchecked {
                minBid = lastHighestBid + ((lastHighestBid * settings.minBidIncrement) / 100);
            }

            if (bidAmount < minBid) revert MINIMUM_BID_NOT_MET();
            if (minBid == 0 && bidAmount == 0 && lastHighestBidder != address(0)) revert MINIMUM_BID_NOT_MET();
        }

        // Transfer QR tokens to this contract BEFORE updating auction state
        // This ensures funds are received before updating the state
        bool success = qrTokenContract.transferFrom(msg.sender, address(this), bidAmount);
        if (!success) revert QR_TOKEN_TRANSFER_FAILED();

        // Update auction state AFTER successful token transfer
        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;
        auction.qrMetadata.validUntil = auction.endTime + settings.duration;
        auction.qrMetadata.urlString = _urlString;

        // Check if auction needs to be extended
        bool extend;
        unchecked {
            extend = (auction.endTime - block.timestamp) < settings.timeBuffer;
            if (extend) {
                auction.endTime = uint40(block.timestamp + settings.timeBuffer);
            }
        }

        // Refund the previous bidder if there was one
        if (lastHighestBidder != address(0) && lastHighestBid > 0) {
            _refundBidder(lastHighestBidder, lastHighestBid);
        }

        emit AuctionBid(_tokenId, msg.sender, bidAmount, extend, auction.endTime, _urlString);
    }

    /// @notice Tries to refund QR tokens to an address, but doesn't stop if it fails
    /// @param _to The address to refund
    /// @param _amount The amount to refund
    function _refundBidder(address _to, uint256 _amount) private {
        if (_amount == 0) return;

        IERC20 qrTokenContract = IERC20(settings.qrToken);
        uint256 contractBalance = qrTokenContract.balanceOf(address(this));
        require(contractBalance >= _amount, "Insufficient contract balance");
        
        // Try to transfer QR tokens back to the previous bidder
        (bool success, bytes memory data) = address(qrTokenContract).call{gas: 50000}(
            abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount)
        );
        
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            emit RefundFailed(_to, _amount, "QR token transfer failed");
        }
    }

    /// @notice Handles critical transfers to the treasury
    /// @param _amount The amount to transfer
    function _handleTreasuryTransfer(uint256 _amount) private {
        if (_amount == 0) return;
        
        // Transfer QR tokens to treasury, if it fails then revert
        IERC20 qrTokenContract = IERC20(settings.qrToken);
        (bool success, bytes memory data) = address(qrTokenContract).call{gas: 50000}(
            abi.encodeWithSelector(IERC20.transfer.selector, settings.treasury, _amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Treasury transfer failed");
    }

    /// @notice Allows a whitelisted settler to manually override the current auction winner
    /// @param _bidder The address to promote to winner
    /// @param _urlString The URL string to set for this bid
    /// @param _refundOriginalWinner Whether to refund the original winner
    /// @dev Only whitelisted settlers can call this function
    function overrideAuctionWinner(
        address _bidder, 
        string memory _urlString, 
        bool _refundOriginalWinner
    ) external nonReentrant whenNotPaused {
        // Check if caller is in whitelist
        if (!_whitelist.settlers[msg.sender]) revert NOT_WHITELISTED_SETTLER();
        
        // Ensure the auction isn't settled yet
        if (auction.settled) revert AUCTION_SETTLED();
        
        // Store the original winner and bid
        address originalWinner = auction.highestBidder;
        uint256 originalBid = auction.highestBid;
        
        // Refund the original winner if requested and there was a winner
        if (_refundOriginalWinner && originalWinner != address(0) && originalBid > 0) {
            _refundBidder(originalWinner, originalBid);
        }
        
        // Update auction with new winner
        auction.highestBidder = _bidder;
        auction.qrMetadata.urlString = _urlString;
        
        emit AuctionWinnerOverridden(
            auction.tokenId, 
            originalWinner, 
            _bidder,
            originalBid, 
            _refundOriginalWinner
        );
    }

    ///                                                          ///
    ///                      WHITELIST MANAGEMENT               ///
    ///                                                          ///

    /// @notice Adds or removes an address from the settler whitelist
    /// @param _settler The settler address to update
    /// @param _status The new status (true = add, false = remove)
    function updateSettlerWhitelist(address _settler, bool _status) external onlyOwner {
        _whitelist.settlers[_settler] = _status;
        emit SettlerWhitelistUpdated(_settler, _status);
    }

    /// @notice Checks if an address is a whitelisted settler
    /// @param _settler The address to check
    /// @return Whether the address is a whitelisted settler
    function isWhitelistedSettler(address _settler) external view returns (bool) {
        return _whitelist.settlers[_settler];
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
    /// @dev Only whitelisted settlers can call this function
    function settleAuction() external nonReentrant whenPaused {
        // Check if caller is in whitelist
        if (!_whitelist.settlers[msg.sender]) revert NOT_WHITELISTED_SETTLER();
        
        _settleAuction();
    }

    ///                                                          ///
    ///                       AUCTION SETTINGS                   ///
    ///                                                          ///

    /// @notice The DAO treasury
    function treasury() external view returns (address) {
        return settings.treasury;
    }

    /// @notice The QR token address
    function qrToken() external view returns (address) {
        return settings.qrToken;
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

    /// @notice Updates the QR token address
    /// @param _qrToken The new QR token address
    function setQRToken(address _qrToken) external onlyOwner whenPaused {
        settings.qrToken = _qrToken;
    }

    ///                                                          ///
    ///                      MIGRATION FUNCTIONS                 ///
    ///                                                          ///

    /// @notice Sets the initial token ID for migration from V1
    /// @param _tokenId The token ID to start from
    /// @dev Can only be called before the first auction is launched
    function setInitialTokenId(uint256 _tokenId) external onlyOwner whenPaused {
        require(!settings.launched, "Auction already launched");
        auction.tokenId = _tokenId;
    }

    /// @notice Sets initial metadata for migration from V1
    /// @param _urlString The URL string from V1
    /// @param _validUntil The validity timestamp from V1
    /// @dev Can only be called before the first auction is launched
    function setInitialMetadata(string memory _urlString, uint256 _validUntil) external onlyOwner whenPaused {
        require(!settings.launched, "Auction already launched");
        settings.qrMetadata.urlString = _urlString;
        settings.qrMetadata.validUntil = _validUntil;
    }
}