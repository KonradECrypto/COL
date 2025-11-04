// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Pfad ggf. an eure Struktur anpassen
import "./Collection-Minting-Transfer.sol"; // nutzt euren zuvor erarbeiteten Core (ERC721 + 4906 + 2981 + WL + Operator-Filter)

/* ───────────────── Base64 (für on-chain Metadata-JSON) ───────────────── */
library Base64 {
    string internal constant _TABLE = "ESF8fMoiUe8DXk0rSNZaBp3erThz1DCDXrSHR2No4AvqWxUA0tHg0I91Z2dWZ4F4";
    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        string memory table = _TABLE;
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        string memory result = new string(encodedLen + 32);
        assembly {
            mstore(result, encodedLen)
            let tablePtr := add(table, 1)
            let dataPtr := data
            let endPtr := add(dataPtr, mload(data))
            let resultPtr := add(result, 32)
            for { } lt(dataPtr, endPtr) { } {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F))))
                resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }
        }
        return result;
    }
}

/**
 * @title COL (Unified Sales & Presentation Wrapper)
 * @notice Schlanke Projekt-Implementierung auf Basis eures MyNFT-Cores.
 *         Bietet Admin-Utilities für Vertrieb UND eine 1/1-Presentations-Prägung
 *         mit on-chain Metadata (image + animation_url + SHA-256 des Dokuments).
 */
contract COL is CircleofLife {
    using Base64 for bytes;

    /* ───────── Projekt-Branding ───────── */
    string public constant CONTRACT_NAME   = "COL Collection";
    string public constant CONTRACT_SYMBOL = "COL";

    /* ───────── Sicherheits-Caps (gas-sicher) ───────── */
    uint256 public constant MAX_MINT_PER_TX = 25;   // konservativ
    uint256 public constant MAX_BATCH_OPS   = 200;  // Airdrop1 max Empfänger/Tx

    /* ───────── Präsentations-Hash (Integrität) ───────── */
    // SHA-256("COL NFT Proj.pdf") – bereits berechnet
    bytes32 public constant DOC_SHA256 = 0x89cc45fc4a7edd44a7dfa18dd580b1611d4e7a5ad8b2d15a27aa180f53dbed80;
    string  public constant DOC_MIME   = "application/pdf";

    /* ───────── Events ───────── */
    event BaseURIUpdated(string newBaseURI);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event MerkleRootUpdated(bytes32 newRoot);
    event OperatorFilterUpdated(address registry, bool enabled);
    event PresentationMinted(address indexed to, uint256 indexed tokenId);
    event TokenURIUpdated(uint256 indexed tokenId, string newURI);

    /* ───────── Präsentations-Metadaten ───────── */
    struct PresentationMeta {
        string name;          // Anzeigename im Marketplace
        string description;   // Beschreibung / Pitch
        string imageURI;      // ipfs://.../cover.png (Poster/Thumbnail)
        string animationURI;  // ipfs://.../slides.pdf | slides.mp4 | /index.html
        string externalURL;   // optional: Website/Microsite/Original
        bytes32 docSha256;    // Integrität
        string  docMime;      // z.B. application/pdf
    }

    constructor(
        string memory baseURI_,
        uint256 maxSupply_,
        address royaltyReceiver_,
        uint96  royaltyBps_,
        uint256 mintPrice_,
        bytes32 merkleRoot_,
        address operatorFilterReg_
    ) MyNFT(CONTRACT_NAME, CONTRACT_SYMBOL, baseURI_, maxSupply_) {
        if (royaltyReceiver_ != address(0) || royaltyBps_ > 0) {
            setDefaultRoyalty(royaltyReceiver_, royaltyBps_);
        }
        if (mintPrice_ > 0)        setMintPrice(mintPrice_);
        if (merkleRoot_ != bytes32(0)) setMerkleRoot(merkleRoot_);
        if (operatorFilterReg_ != address(0)) setOperatorFilterRegistry(operatorFilterReg_, true);
    }

    /* ───────────────────── Admin / Vertrieb ───────────────────── */
    function openSale(uint256 newPrice, bytes32 newRoot) external onlyOwner {
        setMintPrice(newPrice);
        setMerkleRoot(newRoot);
        if (paused) { unpause(); }
    }

    function closeSale() external onlyOwner { if (!paused) { pause(); } }

    function configureRoyalty(address receiver, uint96 bps) external onlyOwner { setDefaultRoyalty(receiver, bps); }

    /// @notice Team-Mint (Owner) in gas-sicherer Größe.
    function teamMint(uint256 amount) external onlyOwner whenNotPaused {
        require(amount > 0 && amount <= MAX_MINT_PER_TX, "AMOUNT_CAP");
        if (totalSupply() + amount > maxSupply) revert MaxSupplyReached();
        mintNext(owner, amount);
    }

    /// @notice Batch-Airdrop (mehrere Empfänger, variable Mengen pro Empfänger).
    function airdrop(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner whenNotPaused {
        require(recipients.length == amounts.length, "LEN_MISMATCH");
        uint256 total;
        for (uint256 i = 0; i < recipients.length; ) {
            uint256 amt = amounts[i];
            require(amt > 0 && amt <= MAX_MINT_PER_TX, "AMOUNT_CAP");
            total += amt;
            unchecked { ++i; }
        }
        if (totalSupply() + total > maxSupply) revert MaxSupplyReached();
        for (uint256 i = 0; i < recipients.length; ) {
            mintNext(recipients[i], amounts[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Airdrop 1 Token pro Empfänger (safeMintNext), capped.
    function airdrop1(address[] calldata recipients) external onlyOwner whenNotPaused {
        uint256 len = recipients.length;
        require(len > 0 && len <= MAX_BATCH_OPS, "LEN_CAP");
        if (totalSupply() + len > maxSupply) revert MaxSupplyReached();
        for (uint256 i = 0; i < len; ) {
            safeMintNext(recipients[i], 1);
            unchecked { ++i; }
        }
    }

    /* ───────────────────── Sichtbarer Präsentations-Mint ───────────────────── */
    /// @notice Mintet genau EIN Token (Auto-ID) an `to` und hinterlegt on-chain Metadata (image + animation_url + Hash).
    function mintPresentation1of1(
        address to,
        string calldata tokenName,
        string calldata description,
        string calldata posterURI,   // ipfs://.../cover.png oder https://...
        string calldata mediaURI,    // ipfs://.../slides.pdf | slides.mp4 | /index.html
        string calldata externalURL
    ) external onlyOwner whenNotPaused returns (uint256 tokenId) {
        require(to != address(0), "ZERO_ADDR");
        require(bytes(posterURI).length != 0, "NO_IMAGE");
        require(bytes(mediaURI).length  != 0, "NO_MEDIA");
        require(maxSupply >= 1, "SUPPLY");

        tokenId = nextId;   // vorab merken (Core: monotone Auto-ID)
        mintNext(to, 1);

        PresentationMeta memory meta = PresentationMeta({
            name: tokenName,
            description: description,
            imageURI: posterURI,
            animationURI: mediaURI,
            externalURL: externalURL,
            docSha256: DOC_SHA256,
            docMime: DOC_MIME
        });
        _setPresentationTokenURI(tokenId, meta);
        emit PresentationMinted(to, tokenId);
    }

    /// @notice Aktualisiert Metadaten eines bestehenden Tokens (ERC-4906-Refresh für Marktplätze).
    function setPresentationFor(uint256 tokenId, PresentationMeta calldata meta) external onlyOwner {
        ownerOf(tokenId); // reverts falls nicht existent
        require(bytes(meta.imageURI).length != 0, "NO_IMAGE");
        require(bytes(meta.animationURI).length != 0, "NO_MEDIA");
        _setPresentationTokenURI(tokenId, meta);
        emit MetadataUpdate(tokenId);
    }

    /* ───────────────────── Internals: URI zusammensetzen ───────────────────── */
    function _setPresentationTokenURI(uint256 tokenId, PresentationMeta memory meta) internal {
        bytes memory json = _buildPresentationJSON(meta);
        string memory dataUri = string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
        setTokenURI(tokenId, dataUri); // MyNFT-Core (onlyOwner)
        emit TokenURIUpdated(tokenId, dataUri);
    }

    function _buildPresentationJSON(PresentationMeta memory meta) internal pure returns (bytes memory) {
        bytes memory ext = bytes(meta.externalURL).length > 0
            ? abi.encode(',"external_url":"', meta.externalURL, '"')
            : bytes("");
        return abi.encodePacked(
            '{',
            '"name":"', _escape(meta.name), '",',
            '"description":"', _escape(meta.description), '",',
            '"image":"', meta.imageURI, '",',
            '"animation_url":"', meta.animationURI, '"',
            ext,
            ',"attributes":[',
            '{"trait_type":"Content","value":"Presentation"},',
            '{"trait_type":"doc_mime","value":"', meta.docMime, '"},',
            '{"trait_type":"doc_sha256","value":"', _toHex(meta.docSha256), '"}',
            ']',
            '}'
        );
    }

    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 len = b.length; if (len == 0) return s;
        bytes memory out = new bytes(len * 2); uint256 j = 0;
        for (uint256 i = 0; i < len; ) {
            bytes1 c = b[i];
            if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = c; }
            else { out[j++] = c; }
            unchecked { ++i; }
        }
        assembly { mstore(out, j) }
        return string(out);
    }

    function _toHex(bytes32 data) internal pure returns (string memory) {
        bytes16 alphabet = 0x30313233343536373839616263646566; // 0-9 a-f
        bytes memory str = new bytes(66);
        str[0] = '0'; str[1] = 'x';
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(data[i]);
            str[2 + i*2] = bytes1(alphabet[b >> 4]);
            str[3 + i*2] = bytes1(alphabet[b & 0x0f]);
        }
        return string(str);
    }

    /* ───────────────────── Compact Config View ───────────────────── */
    function config()
    external
    view
    returns (
        string memory colName,
        string memory colSymbol,
        uint256 _maxSupply,
        uint256 _totalSupply,
        uint256 _nextId,
        uint256 _mintPrice,
        address _royaltyReceiver,
        uint96  _royaltyBps,
        bool    _paused
    )
    {
        return (
            _name,              // direkt aus Core (internal)
            _symbol,            // direkt aus Core (internal)
            maxSupply,
            totalSupply(),
            nextId,
            mintPrice,          // public state aus Core
            royaltyReceiver,    // public state aus Core
            royaltyBps,         // public state aus Core
            paused
        );
    }
}
