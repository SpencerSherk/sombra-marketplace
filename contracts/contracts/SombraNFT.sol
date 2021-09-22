pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract SombraNFT is ERC721 {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    constructor() ERC721("SombraNFT", "SNFT") {}

    struct Item {
        address minter;
        string uri;
    }

    mapping(uint256 => Item) public Items;

    function createItem(string memory uri) public returns (uint256) {
        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();
        _safeMint(msg.sender, newItemId);

        Items[newItemId] = Item(msg.sender, uri);

        return newItemId;
    }

    function minter(uint256 tokenId)
        public
        view
        returns (address)
    {
        require(
            _exists(tokenId),
            "ERC721Metadata: minter query for nonexistent token"
        );

        return Items[tokenId].minter;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );

        return Items[tokenId].uri;
    }
}
