contract CircleofLife is ERC721, Ownable, IERC2981 {
    // --- Limits (Gas-sichere Obergrenzen) ---
    uint256 public constant MAX_MINT_PER_TX  = 25;  // Owner/public: max Stück pro TX
    uint256 public constant MAX_BATCH_OPS    = 50;  // Batch-Transfers/Burns: max IDs pro TX

    // Royalties (global)
    address public royaltyReceiver;
    uint96  public royaltyBps; // Basis-Punkte (10000 = 100%)

    // Sequentielles Minting (monoton)
    uint256 public nextId; // startet bei 1

    // Paid Minting
    uint256 public mintPrice;

    // Whitelist (MerkleProof)
    bytes32 public merkleRoot;
    mapping(address => bool) public hasMinted; // einfacher 1x-Claim

    // Events
    event BaseURIUpdated(string newBaseURI);
    event MaxSupplyUpdated(uint256 oldMax, uint256 newMax);
    event DefaultRoyaltyUpdated(address receiver, uint96 bps);
    event NextIdUpdated(uint256 oldNext, uint256 newNext);
    event Withdraw(address indexed to, uint256 amount);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event MerkleRootUpdated(bytes32 newRoot);
    event OperatorFilterUpdated(address registry, bool enabled);
    event TokenURIUpdated(uint256 indexed tokenId, string newURI);

    // Errors
    error WithdrawFailed();
    error InvalidProof();
    error AlreadyClaimed();
    error ExceedsPerTxLimit();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        uint256 maxSupply_
    ) ERC721(name_, symbol_, baseURI_, maxSupply_) {
        nextId = 1;
    }

    /* -------------------- Versionierung -------------------- */
    function version() external pure returns (string memory) {
        return "MyNFT_ERC721_v1.4.2";
    }

    /* -------------------- Operator Filtering Controls -------------------- */
    function setOperatorFilterRegistry(address registry, bool enabled) external onlyOwner {
        _operatorFilterRegistry = registry;
        _operatorFilteringEnabled = enabled && registry != address(0);
        emit OperatorFilterUpdated(registry, _operatorFilteringEnabled);
    }

    /* -------------------- Per-Token Metadata Controls -------------------- */
    function setTokenURI(uint256 tokenId, string calldata newURI) external onlyOwner {
        if (!_exists(tokenId)) revert NonExistentToken();
        _tokenURIs[tokenId] = newURI;
        emit TokenURIUpdated(tokenId, newURI);
        emit MetadataUpdate(tokenId);
    }
    function clearTokenURI(uint256 tokenId) external onlyOwner {
        if (!_exists(tokenId)) revert NonExistentToken();
        delete _tokenURIs[tokenId];
        emit MetadataUpdate(tokenId);
    }

    /* -------------------- Owner-Mint (monoton, ohne unnötige Guards) -------------------- */
    function mintNext(address to, uint256 amount) external payable onlyOwner whenNotPaused {
        if (msg.value != 0) revert OwnerMintMustBeFree();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > MAX_MINT_PER_TX) revert ExceedsPerTxLimit();
        if (totalSupply + amount > maxSupply) revert MaxSupplyReached();

        uint256 id = nextId;
        for (uint256 i = 0; i < amount; ) {
            _mint(to, id);
            unchecked { ++id; ++i; }
        }
        emit NextIdUpdated(nextId, id);
        nextId = id;
    }

    function safeMintNext(address to, uint256 amount) external payable onlyOwner whenNotPaused {
        if (msg.value != 0) revert OwnerMintMustBeFree();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > MAX_MINT_PER_TX) revert ExceedsPerTxLimit();
        if (totalSupply + amount > maxSupply) revert MaxSupplyReached();

        uint256 id = nextId;
        for (uint256 i = 0; i < amount; ) {
            _safeMint(to, id);
            unchecked { ++id; ++i; }
        }
        emit NextIdUpdated(nextId, id);
        nextId = id;
    }

    /* -------------------- Public Mint (WL + Refund) -------------------- */
    function publicMint(bytes32[] calldata proof) external payable whenNotPaused nonReentrant {
        if (msg.value < mintPrice) revert InsufficientPayment();
        if (hasMinted[msg.sender]) revert AlreadyClaimed();

        // WL-Check
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!_verifyMerkle(proof, merkleRoot, leaf)) revert InvalidProof();

        // Effects
        hasMinted[msg.sender] = true;

        // monotone ID (immer 1 pro TX hier)
        uint256 id = nextId;
        if (totalSupply + 1 > maxSupply) revert MaxSupplyReached();
        _mint(msg.sender, id);
        nextId = id + 1;
        emit NextIdUpdated(id, nextId);

        // Refund Überzahlung
        uint256 excess = msg.value - mintPrice;
        if (excess > 0) {
            (bool ok, ) = msg.sender.call{value: excess}("");
            if (!ok) revert WithdrawFailed();
        }
    }

    // Merkle-Helper
    function _verifyMerkle(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; ) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
            unchecked { ++i; }
        }
        return computedHash == root;
    }

    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }

    function setMintPrice(uint256 newPrice) external onlyOwner {
        uint256 old = mintPrice;
        mintPrice = newPrice;
        emit MintPriceUpdated(old, newPrice);
    }

    /* -------------------- Transfers/Burns mit Caps -------------------- */
    function batchTransferFrom(address from, address to, uint256[] calldata tokenIds)
    external
    whenNotPaused
    onlyAllowedOperator(from)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 len = tokenIds.length;
        if (len == 0 || len > MAX_BATCH_OPS) revert ExceedsPerTxLimit();

        for (uint256 i = 0; i < len; ) {
            uint256 id = tokenIds[i];
            address owner_ = ownerOf(id);
            if (owner_ != from) revert NotAuthorized();
            if (!_isApprovedOrOwner(owner_, msg.sender, id)) revert NotAuthorized();
            _transfer(from, to, id);
            unchecked { ++i; }
        }
    }

    function batchSafeTransferFrom(address from, address to, uint256[] calldata tokenIds, bytes calldata data)
    external
    whenNotPaused
    onlyAllowedOperator(from)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 len = tokenIds.length;
        if (len == 0 || len > MAX_BATCH_OPS) revert ExceedsPerTxLimit();

        for (uint256 i = 0; i < len; ) {
            uint256 id = tokenIds[i];
            address owner_ = ownerOf(id);
            if (owner_ != from) revert NotAuthorized();
            if (!_isApprovedOrOwner(owner_, msg.sender, id)) revert NotAuthorized();
            _transfer(from, to, id);
            if (
                to.code.length != 0 &&
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, data)
                != IERC721Receiver.onERC721Received.selector
            ) revert UnsafeRecipient();
            unchecked { ++i; }
        }
    }

    function burn(uint256 tokenId) external whenNotPaused {
        address owner_ = ownerOf(tokenId);
        if (!_isApprovedOrOwner(owner_, msg.sender, tokenId)) revert NotAuthorized();
        _burn(tokenId);
    }

    function batchBurn(uint256[] calldata tokenIds) external whenNotPaused {
        uint256 len = tokenIds.length;
        if (len == 0 || len > MAX_BATCH_OPS) revert ExceedsPerTxLimit();

        for (uint256 i = 0; i < len; ) {
            uint256 id = tokenIds[i];
            address owner_ = ownerOf(id);
            if (!_isApprovedOrOwner(owner_, msg.sender, id)) revert NotAuthorized();
            _burn(id);
            unchecked { ++i; }
        }
    }

    /* -------------------- Metadata/Config -------------------- */
    function setBaseURI(string calldata newBase) external onlyOwner {
        _baseURI = newBase;
        emit BaseURIUpdated(newBase);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function setMaxSupply(uint256 newMaxSupply) external onlyOwner {
        uint256 old = maxSupply;
        if (newMaxSupply < totalSupply) revert InvalidMaxSupply();
        maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(old, newMaxSupply);
    }

    /* -------------------- ERC-2981 (global) -------------------- */
    function setDefaultRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps > 10_000) revert NotAuthorized();
        if (bps != 0 && receiver == address(0)) revert ZeroAddress();
        royaltyReceiver = receiver;
        royaltyBps = bps;
        emit DefaultRoyaltyUpdated(receiver, bps);
    }

    function royaltyInfo(uint256, uint256 salePrice)
    external
    view
    override
    returns (address receiver, uint256 royaltyAmount)
    {
        receiver = royaltyReceiver;
        royaltyAmount = (salePrice * royaltyBps) / 10_000;
    }

    function supportsInterface(bytes4 interfaceId)
    public
    view
    override(ERC721, IERC165)
    returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IERC2981).interfaceId;
    }

    /* -------------------- ETH Handling -------------------- */
    receive() external payable {}
    function withdraw(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdraw(to, amount);
    }

    /* -------------------- Pause Controls -------------------- */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
