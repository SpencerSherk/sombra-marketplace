pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface SombraNFT {
    function minter(uint256 id) external returns (address);
}

// Not to be confused with the actual WETH contract. This is a simple
// contract to keep track of ETH/BNB the user is owned by the contract.
//
// The user can withdraw it at any moment, it's not a token, hence it's not
// transferable. The marketplace will automatically try to refund the ETH to
// the user (e.g outbid, NFT sold) with a gas limit. This is simply backup
// when the ETH/BNB could not be sent to the user/address. For example, if
// the user is a smart contract that uses a lot of gas on it's payable.
contract WrappedETH is ReentrancyGuard {
    mapping(address => uint256) public wethBalance;

    function claimBNB() external nonReentrant {
        uint256 refund = wethBalance[msg.sender];
        wethBalance[msg.sender] = 0;
        msg.sender.call{value: refund};
    }

    // claimBNBForUser tries to payout the user's owned balance with
    // a gas limit.
    function claimBNBForUser(address user) external nonReentrant {
        uint256 refund = wethBalance[user];
        wethBalance[user] = 0;
        user.call{value: refund, gas: 3500};
    }

    // rewardBNBToUserAndClaim increases the user's internal BNB balance and
    // tries to payout their entire balance safely.
    function rewardBNBToUserAndClaim(address user, uint256 amount) internal {
        wethBalance[user] += amount;
        try this.claimBNBForUser(user) {} catch {}
    }

    function rewardBNBToUser(address user, uint256 amount) internal {
        wethBalance[user] += amount;
    }
}

contract Buyback {
    // Uniswap V2 Router address for buyback functionality.
    IUniswapV2Router02 public uniswapV2Router;
    // Keep store of the WETH address to save on gas.
    address WETH;

    address constant burnAddress = address(0x000000000000000000000000000000000000dEaD);

    uint256 ethToBuybackWith = 0;

    event UniswapRouterUpdated(
        address newAddress
    );

    event SombraBuyback(
        uint256 ethSpent
    );

    function updateBuybackUniswapRouter(address newRouterAddress) internal {
        uniswapV2Router = IUniswapV2Router02(newRouterAddress);
        WETH = uniswapV2Router.WETH();

        emit UniswapRouterUpdated(newRouterAddress);
    }

    function buybackSombra() external {
        require(msg.sender == address(this), "can only be called by the contract");
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(this);

        uint256 amount = ethToBuybackWith;
        ethToBuybackWith = 0;

        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0, // accept any amount of Tokens
            path,
            burnAddress, // Burn the buyback tokens (@note: subject to change)
            block.timestamp
        );
        
        emit SombraBuyback(amount);
    }

    function swapETHForTokens(uint256 amount) internal {
        ethToBuybackWith += amount;
        // 500k gas is more than enough.
        try this.buybackSombra{gas: 500000}() {} catch {}
    }
}

contract SombraMarketplace is ReentrancyGuard, Ownable, WrappedETH, Buyback {
    // MarketItem consists of buy-now and bid items.
    // Auction refers to items that can be bid on.
    // An item can either be buy-now or bid, or both.
    struct MarketItem {
        uint256 tokenId;

        address payable seller;

        // If purchasePrice is non-0, item can be bought out-right for that price
        // if bidPrice is non-0, item can be bid upon.
        uint256 purchasePrice;
        uint256 bidPrice;

        uint8 state;
        uint64 listingCreationTime;
        uint64 auctionStartTime; // Set when first bid is received. 0 until then.
        uint64 auctionEndTime; // Initially it is the DURATION of the auction.
                               // After the first bid, it is set to the END time
                               // of the auction.

        // Defaults to 0. When 0, no bid has been placed yet.
        address payable highestBidder;
    }

    uint8 constant ON_MARKET = 0;
    uint8 constant SOLD = 1;
    uint8 constant CANCELLED = 2;

    // itemsOnMarket is a list of all items, historic and current, on the marketplace.
    // This includes items all of states, i.e items are never removed from this list.
    MarketItem[] public itemsOnMarket;

    // sombraNFTAddress is the address for the Sombra NFT address.
    address immutable public sombraNFTAddress;
    
    // devWalletAddress is the Sombra development address for 10% fees.
    address constant public devWalletAddress = 0x949d36d76236217D4Fae451000861B535D9500Ab;

    event AuctionItemAdded(
        uint256 tokenId,
        address tokenAddress,
        uint256 bidPrice,
        uint256 auctionDuration
    );

    event FixedPriceItemAdded(
        uint256 id,
        uint256 tokenId,
        address tokenAddress,
        uint256 purchasePrice
    );

    event ItemSold(
        uint256 id,
        address buyer,
        uint256 purchasePrice,
        uint256 bidPrice
    );
 
    event HighestBidIncrease(
        uint256 id,
        address bidder,
        uint256 amount,
        uint256 auctionEndTime
    );

    event PriceReduction(
        uint256 tokenAddress,
        uint256 newPurchasePrice,
        uint256 newBidPrice
    );
 
    event ItemPulledFromMarket(uint256 id);
    
    constructor(address _sombraNFTAddress, address _uniswapRouterAddress) {
        sombraNFTAddress = _sombraNFTAddress;
        
        updateBuybackUniswapRouter(_uniswapRouterAddress);
    }

    function updateUniswapRouter(address newRouterAddress) external onlyOwner {
        updateBuybackUniswapRouter(newRouterAddress);
    }

    function isMinter(uint256 id, address target) internal returns (bool) {
        SombraNFT sNFT = SombraNFT(sombraNFTAddress);
        return sNFT.minter(id) == target;
    }

    function minter(uint256 id) internal returns (address) {
        SombraNFT sNFT = SombraNFT(sombraNFTAddress);
        return sNFT.minter(id);
    }
    
    function handleFees(uint256 id, uint256 amount, bool isMinterSale) internal returns (uint256) {
        uint256 buybackFee;
        if(!isMinterSale) {
            // In resale, 5% buyback and 5% to artist.
            // 90% to seller.
            buybackFee = amount * 105 / 100;
            
            uint256 artistFee = amount * 105 / 100;
            rewardBNBToUserAndClaim(minter(id), artistFee);
            amount = amount - artistFee;
        } else {
            // When it's the minter selling, they get 80%
            // 10% to buyback
            // 10% to SOMBRA dev wallet.
            buybackFee = amount * 110 / 100;
            
            uint256 devFee = amount * 110 / 100;
            rewardBNBToUserAndClaim(devWalletAddress, devFee);
            amount = amount - devFee;
        }
        
        swapETHForTokens(buybackFee);
        
        return amount - buybackFee;
    }
    
    function createAuctionItem(
        uint256 tokenId,
        address seller,
        uint256 purchasePrice,
        uint256 startingBidPrice,
        uint256 biddingTime
    ) internal {
        itemsOnMarket.push(
            MarketItem(
                tokenId,
                payable(seller),
                purchasePrice,
                startingBidPrice,
                ON_MARKET,
                uint64(block.timestamp),
                uint64(0),
                uint64(biddingTime),
                payable(address(0))
            )
        );
    }
    
    // purchasePrice is the direct purchasing price. Starting bid price
    // is the starting price for bids. If purchase price is 0, item cannot
    // be bought directly. Similarly for startingBidPrice, if it's 0, item
    // cannot be bid upon. One of them must be non-zero.
    function listItemOnAuction(
        address tokenAddress,
        uint256 tokenId,
        uint256 purchasePrice,
        uint256 startingBidPrice,
        uint256 biddingTime
    )
        external
        returns (uint256)
    {
        IERC721 tokenContract = IERC721(tokenAddress);
        require(tokenAddress == sombraNFTAddress, "Item must be Sombra NFT");
        require(tokenContract.ownerOf(tokenId) == msg.sender, "Missing Item Ownership");
        require(tokenContract.getApproved(tokenId) == address(this), "Missing transfer approval");

        require(purchasePrice > 0 || startingBidPrice > 0, "Item must have a price");
        require(startingBidPrice == 0 || biddingTime > 3600, "Bidding time must be above one hour");
        
        uint256 newItemId = itemsOnMarket.length;
        createAuctionItem(
            tokenId,
            msg.sender,
            purchasePrice,
            startingBidPrice,
            biddingTime
        );
        
        IERC721(sombraNFTAddress).transferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        if(purchasePrice > 0) {
            emit FixedPriceItemAdded(newItemId, tokenId, tokenAddress, purchasePrice);
        }

        if(startingBidPrice > 0) {
            emit AuctionItemAdded(
                tokenId,
                sombraNFTAddress,
                startingBidPrice,
                biddingTime
            );
        }
        return newItemId;
    }

    function buyFixedPriceItem(uint256 id)
        external
        payable
        nonReentrant
    {
        require(id < itemsOnMarket.length, "Invalid id");
        MarketItem memory item = itemsOnMarket[id];

        require(item.state == ON_MARKET, "Item not for sale");
        
        require(msg.value >= item.purchasePrice, "Not enough funds sent");
        require(item.purchasePrice > 0, "Item does not have a purchase price.");

        require(msg.sender != item.seller, "Seller can't buy");
        
        item.state = SOLD;
        IERC721(sombraNFTAddress).safeTransferFrom(
            address(this),
            msg.sender,
            item.tokenId
        );
        
        uint256 netPrice = handleFees(id, item.purchasePrice, isMinter(id, item.seller));
        rewardBNBToUser(item.seller, netPrice);

        emit ItemSold(id, msg.sender, item.purchasePrice, item.bidPrice);

        itemsOnMarket[id] = item;

        // If the user sent excess ETH/BNB, send any extra back to the user.
        uint256 refundableEther = msg.value - item.purchasePrice;
        if(refundableEther > 0) {
            payable(msg.sender).call{value: refundableEther};
        }

        try this.claimBNBForUser(item.seller) {} catch {}
    }

    function placeBid(uint256 id)
        external
        payable
        nonReentrant
    {
        require(id < itemsOnMarket.length, "Invalid id");
        MarketItem memory item = itemsOnMarket[id];

        require(item.state == ON_MARKET, "Item not for sale");
        
        require(block.timestamp < item.auctionEndTime || item.highestBidder == address(0), "Auction has ended");
        
        if (item.highestBidder != address(0)) {
            require(msg.value >= item.bidPrice * 105 / 100, "Bid must be 5% higher than previous bid");
        } else {
            require(msg.value >= item.bidPrice, "Too low bid");

            // First bid!
            item.auctionStartTime = uint64(block.timestamp);
            // item.auctionEnd is the auction duration. Add current time to it
            // to set it to the end time.
            item.auctionEndTime += uint64(block.timestamp);
        }

        address previousBidder = item.highestBidder;
        // Return BNB to previous highest bidder.
        if (previousBidder != address(0)) {
            rewardBNBToUser(previousBidder, item.bidPrice);
        }

        item.highestBidder = payable(msg.sender);
        item.bidPrice = msg.value;
        // Extend the auction time by 5 minutes if there is less than 5 minutes remaining.
        // This is to prevent snipers sniping in the last block, and give everyone a chance
        // to bid.
        if ((item.auctionEndTime - block.timestamp) < 300){
            item.auctionEndTime = uint64(block.timestamp + 300);
        }

        emit HighestBidIncrease(id, msg.sender, msg.value, item.auctionEndTime);

        itemsOnMarket[id] = item;

        if (previousBidder != address(0)) {
            try this.claimBNBForUser(previousBidder) {} catch {}
        }
    }

    function closeAuction(uint256 id)
        external
    {
        require(id < itemsOnMarket.length, "Invalid id");
        MarketItem memory item = itemsOnMarket[id];

        require(item.state == ON_MARKET, "Item not for sale");
        require(item.bidPrice > 0, "Item is not on auction.");
        require(item.highestBidder != address(0), "No bids placed");
        require(block.timestamp > item.auctionEndTime, "Auction is still on going");
        
        item.state = SOLD;
        
        IERC721(sombraNFTAddress).transferFrom(
            address(this),
            item.highestBidder,
            item.tokenId
        );
        
        uint256 netPrice = handleFees(id, item.bidPrice, isMinter(id, item.seller));
        rewardBNBToUser(item.seller, netPrice);
        
        emit ItemSold(id, item.highestBidder, item.purchasePrice, item.bidPrice);

        try this.claimBNBForUser(item.seller) {} catch {}
        itemsOnMarket[id] = item;
    }

    function reducePrice(
        uint256 id,
        uint256 reducedPrice,
        uint256 reducedBidPrice
    )
        external
    {
        require(id < itemsOnMarket.length, "Invalid id");
        MarketItem memory item = itemsOnMarket[id];
        require(item.state == ON_MARKET, "Item not for sale");

        require(msg.sender == item.seller, "Only the item seller can trigger a price reduction");
        require(block.timestamp >= item.listingCreationTime + 600, "Must wait ten minutes after listing before lowering the listing price");
        require(item.highestBidder == address(0), "Cannot reduce price once a bid has been placed");
        require(reducedBidPrice > 0 || reducedPrice > 0, "Must reduce price");

        if (reducedPrice > 0) {
            require(
                item.purchasePrice > 0 && reducedPrice <= item.purchasePrice * 95 / 100,
                "Reduced price must be at least 5% less than the current price"
            );
            item.purchasePrice = reducedPrice;

        }

        if (reducedBidPrice > 0) {
            require(
                item.bidPrice > 0 && reducedBidPrice <= item.bidPrice * 95 / 100,
                "Reduced price must be at least 5% less than the current price"
            );
            item.bidPrice = reducedPrice;
        }

        itemsOnMarket[id] = item;

        emit PriceReduction(
            id,
            item.purchasePrice,
            item.bidPrice
        );
    }

    function pullFromMarket(uint256 id)
        external
    {
        require(id < itemsOnMarket.length, "Invalid id");
        MarketItem memory item = itemsOnMarket[id];

        require(item.state == ON_MARKET, "Item not for sale");
        require(msg.sender == item.seller, "Only the item seller can pull an item from the marketplace");

        // Up for debate: Currently we don't allow items to be pulled if it's been bid on
        require(item.highestBidder == address(0), "Cannot pull from market once a bid has been placed");
        require(block.timestamp >= item.listingCreationTime + 600, "Must wait ten minutes after listing before pulling from the market");
        item.state = CANCELLED;

        IERC721(sombraNFTAddress).transferFrom(
            address(this),
            item.seller,
            item.tokenId
        );
        itemsOnMarket[id] = item;

        emit ItemPulledFromMarket(id);
    }
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

// pragma solidity >=0.6.2;
interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}
