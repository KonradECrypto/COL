// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

abstract contract ERC721 is IERC721, IERC721Metadata, IERC4906 {
    // Core Storage
    mapping(uint256 => address) internal _ownerOf; // tokenId => owner
    mapping(address => uint256) internal _balanceOf; // owner => balance
    mapping(uint256 => address) internal _approvals; // tokenId => approved
    mapping(address => mapping(address => bool)) public override isApprovedForAll;
    string internal _name;
    string internal _symbol;
    string internal _baseURI;
    bool public paused;                // pausiert Transfers/Mints/Burns (nicht Approvals)
    uint256 public maxSupply;          // Hard cap
    uint256 public totalSupply;        // umlaufende Menge
    uint256 private _burned;           // Burn-Accounting

    // Per-Token URI (optional)
    mapping(uint256 => string) internal _tokenURIs;

    // Operator Filter (optional)
    address internal _operatorFilterRegistry; // 0 = deaktiviert
    bool internal _operatorFilteringEnabled;

    // Custom Errors
    error NonExistentToken();
    error ZeroAddress();
    error NotAuthorized();
    error UnsafeRecipient();
    error ContractPaused();
    error ReentrancyDetected();
    error MaxSupplyReached();
    error InvalidMaxSupply();
    error InsufficientPayment();
    error OwnerMintMustBeFree();

    // Pause-Events
    event Paused(address account);
    event Unpaused(address account);

    // Reentrancy-Lock (nur dort einsetzen, wo externe Calls erfolgen)
    bool private _locked;
    modifier nonReentrant() {
        if (_locked) revert ReentrancyDetected();
        _locked = true;
        _;
        _locked = false;
    }

    // Operator-Filter Modifiers
    modifier onlyAllowedOperator(address from) {
        if (_operatorFilteringEnabled && _operatorFilterRegistry != address(0) && from != msg.sender) {
            if (!IOperatorFilterRegistry(_operatorFilterRegistry).isOperatorAllowed(address(this), msg.sender)) {
                revert NotAuthorized();
            }
        }
        _;
    }
    modifier onlyAllowedOperatorApproval(address operator) {
        if (_operatorFilteringEnabled && _operatorFilterRegistry != address(0)) {
            if (!IOperatorFilterRegistry(_operatorFilterRegistry).isOperatorAllowed(address(this), operator)) {
                revert NotAuthorized();
            }
        }
        _;
    }

    // Constructor
    constructor(string memory name_, string memory symbol_, string memory baseURI_, uint256 maxSupply_) {
        _name = name_;
        _symbol = symbol_;
        _baseURI = baseURI_;
        maxSupply = maxSupply_;
    }

    // ERC165
    function supportsInterface(bytes4 interfaceId)
    public
    pure
    virtual
    override
    returns (bool)
    {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == 0x49064906; // ERC-4906
    }

    // Metadata
    function name() external view override returns (string memory) { return _name; }
    function symbol() external view override returns (string memory) { return _symbol; }
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        if (!_exists(tokenId)) revert NonExistentToken();
        string memory custom = _tokenURIs[tokenId];
        if (bytes(custom).length != 0) return custom;
        return string(abi.encodePacked(_baseURI, _toString(tokenId), ".json"));
    }

    // Views
    function ownerOf(uint256 tokenId) public view override returns (address owner_) {
        owner_ = _ownerOf[tokenId];
        if (owner_ == address(0)) revert NonExistentToken();
    }
    function balanceOf(address owner_) external view override returns (uint256) {
        if (owner_ == address(0)) revert ZeroAddress();
        return _balanceOf[owner_];
    }
    function getApproved(uint256 tokenId) external view override returns (address) {
        if (!_exists(tokenId)) revert NonExistentToken();
        return _approvals[tokenId];
    }
    function totalBurned() public view returns (uint256) { return _burned; }

    // Approvals (nicht pausiert) + optional Operator-Filter
    function setApprovalForAll(address operator, bool approved)
    external
    override
    onlyAllowedOperatorApproval(operator)
    {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }
    function approve(address to, uint256 tokenId)
    external
    override
    onlyAllowedOperatorApproval(to)
    {
        if (!_exists(tokenId)) revert NonExistentToken();
        address owner_ = _ownerOf[tokenId];
        if (to == owner_) revert NotAuthorized();
        if (msg.sender != owner_ && !isApprovedForAll[owner_][msg.sender]) revert NotAuthorized();
        _approvals[tokenId] = to;
        emit Approval(owner_, to, tokenId);
    }

    // Transfers
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    function transferFrom(address from, address to, uint256 tokenId)
    public
    virtual
    override
    whenNotPaused
    onlyAllowedOperator(from)
    {
        if (to == address(0)) revert ZeroAddress();
        address owner_ = ownerOf(tokenId);
        if (owner_ != from) revert NotAuthorized();
        if (!_isApprovedOrOwner(owner_, msg.sender, tokenId)) revert NotAuthorized();
        _transfer(from, to, tokenId);
    }
    function safeTransferFrom(address from, address to, uint256 tokenId)
    external
    override
    whenNotPaused
    onlyAllowedOperator(from)
    {
        safeTransferFrom(from, to, tokenId, "");
    }
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data)
    public
    override
    whenNotPaused
    onlyAllowedOperator(from)
    {
        if (to == address(0)) revert ZeroAddress();
        address owner_ = ownerOf(tokenId);
        if (owner_ != from) revert NotAuthorized();
        if (!_isApprovedOrOwner(owner_, msg.sender, tokenId)) revert NotAuthorized();

        _transfer(from, to, tokenId);

        if (
            to.code.length != 0 &&
            IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
            != IERC721Receiver.onERC721Received.selector
        ) {
            revert UnsafeRecipient();
        }
    }

    // Internals
    function _transfer(address from, address to, uint256 tokenId) internal virtual {
        // Clear approvals
        if (_approvals[tokenId] != address(0)) {
            delete _approvals[tokenId];
            emit Approval(from, address(0), tokenId);
        }
        // Update balances & ownership
        unchecked { _balanceOf[from] -= 1; _balanceOf[to] += 1; }
        _ownerOf[tokenId] = to;

        emit Transfer(from, to, tokenId);
        _afterTokenTransfer(from, to, tokenId);
    }

    function _mint(address to, uint256 tokenId) internal virtual {
        if (to == address(0)) revert ZeroAddress();
        if (_exists(tokenId)) revert NotAuthorized();
        if (totalSupply + 1 > maxSupply) revert MaxSupplyReached();

        unchecked { _balanceOf[to] += 1; totalSupply += 1; }
        _ownerOf[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
        _afterTokenTransfer(address(0), to, tokenId);
    }

    function _safeMint(address to, uint256 tokenId) internal virtual {
        _mint(to, tokenId);
        if (
            to.code.length != 0 &&
            IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "")
            != IERC721Receiver.onERC721Received.selector
        ) {
            revert UnsafeRecipient();
        }
    }

    function _burn(uint256 tokenId) internal virtual {
        address owner_ = ownerOf(tokenId); // reverts if non-existent

        if (_approvals[tokenId] != address(0)) {
            delete _approvals[tokenId];
            emit Approval(owner_, address(0), tokenId);
        }

        unchecked { _balanceOf[owner_] -= 1; totalSupply -= 1; _burned += 1; }
        delete _ownerOf[tokenId];

        emit Transfer(owner_, address(0), tokenId);
        _afterTokenTransfer(owner_, address(0), tokenId);
    }

    function _isApprovedOrOwner(address owner_, address spender, uint256 tokenId)
    internal
    view
    returns (bool)
    {
        return (spender == owner_ || isApprovedForAll[owner_][spender] || spender == _approvals[tokenId]);
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf[tokenId] != address(0);
    }

    function _afterTokenTransfer(address from, address to, uint256 tokenId) internal virtual {}

    // Utils
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) { digits -= 1; buffer[digits] = bytes1(uint8(48 + uint256(value % 10))); value /= 10; }
        return string(buffer);
    }
}
