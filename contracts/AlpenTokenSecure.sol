// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
// ReentrancyGuard für zusätzlichen Schutz (obwohl OpenZeppelin's _update per se keine externen Calls macht)
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AlpenTokenSecure is ERC20, Ownable, ReentrancyGuard {
    
    // 1. ZENTRALISIERUNGS-FIX: "immutable" bedeutet, diese Adressen können nach dem 
    // Deployment NIEMALS wieder geändert werden. Kein Rug-Pull der Spendengelder möglich!
    address public immutable charityWallet;
    address public immutable oracleServer;
    
    // 2. SLIPPAGE & WHALE FIX: Hardcodiertes Limit. Kann nicht manipuliert werden.
    uint256 public immutable maxTxAmount; 

    uint256 public taxRate = 2; // Startwert 2%

    // 3. FRONT-RUNNING & SNIPER BOT FIX: Block-Cooldown für Überweisungen
    mapping(address => uint256) private _lastTransferBlock;
    bool public cooldownEnabled = true;

    event TaxSentToCharity(address indexed from, uint256 amount);
    event AvalancheRiskUpdated(uint8 newRiskLevel, uint256 newTaxRate);

    constructor(address _charityWallet, address _oracleServer) 
        ERC20("AlpenToken", "ALPN") 
        Ownable(msg.sender) 
    {
        require(_charityWallet != address(0), "Ungueltige Charity Wallet");
        require(_oracleServer != address(0), "Ungueltiger Oracle Server");
        
        charityWallet = _charityWallet;
        oracleServer = _oracleServer;

        uint256 initialSupply = 1000000000 * 10 ** decimals(); // 1 Milliarde
        
        // Festes Anti-Whale Limit (1%)
        maxTxAmount = (initialSupply * 1) / 100; 

        _mint(msg.sender, initialSupply);
    }

    // _update wird überschrieben. Da OpenZeppelin's _update intern ist und wir hier 
    // nur Balances verschieben, ist eine klassische Reentrancy ausgeschlossen. 
    // Der nonReentrant Modifier ist auf externen Calls (wie updateAvalancheRisk) wichtiger, 
    // kann aber theoretisch als Wrapper genutzt werden, falls Custom-Hooks später dazukommen.
    function _update(address from, address to, uint256 value) internal override {
        // ZENTRALISIERUNGS-FIX: Keine beliebige "excludeFromFees" Funktion mehr!
        // Nur der Owner (für initiale Liquidität) und der Contract selbst sind befreit.
        if (from == address(0) || to == address(0) || from == owner() || from == address(this)) {
            super._update(from, to, value);
            return;
        }

        // 3. BOT-SCHUTZ: Verhindert, dass Bots/Wale mehrere Transaktionen in einem einzigen Block ausführen (Front-Running/Arbitrage)
        if (cooldownEnabled) {
            require(_lastTransferBlock[from] != block.number, "Bot-Schutz: Nur 1 Transaktion pro Block erlaubt");
            _lastTransferBlock[from] = block.number;
        }

        // Anti-Whale Check
        require(value <= maxTxAmount, "Touristen-Schranke: Tx Limit ueberschritten");

        // Steuern berechnen
        uint256 taxAmount = (value * taxRate) / 100;
        uint256 sendAmount = value - taxAmount;

        if (taxAmount > 0) {
            super._update(from, charityWallet, taxAmount);
            emit TaxSentToCharity(from, taxAmount);
        }
        
        super._update(from, to, sendAmount);
    }

    // 4. ORACLE FIX: Nur der immutable Server darf das aufrufen. Admin hat KEINE Macht mehr darüber.
    function updateAvalancheRisk(uint8 _riskLevel) external nonReentrant {
        require(msg.sender == oracleServer, "Nur autorisierter Server");
        require(_riskLevel >= 1 && _riskLevel <= 5, "Ungueltige Warnstufe");
        
        // Hardcodierte Logik, die nicht vom Owner missbraucht werden kann
        if (_riskLevel <= 2) {
            taxRate = 2;
        } else if (_riskLevel == 3) {
            taxRate = 4;
        } else {
            taxRate = 6;
        }

        emit AvalancheRiskUpdated(_riskLevel, taxRate);
    }

    // Funktion um den Cooldown später abzuschalten, falls er nach der heißen Launch-Phase
    // ehrliche Trader bei Arbitrage/Router-Swaps behindert.
    function disableCooldown() external onlyOwner {
        cooldownEnabled = false;
    }
}