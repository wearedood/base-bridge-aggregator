// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BaseBridgeAggregator
 * @dev Advanced cross-chain bridge aggregator for Base ecosystem
 * Supports multiple bridge protocols with optimal routing and MEV protection
 */
contract BaseBridgeAggregator is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct BridgeRoute {
        address bridgeContract;
        uint256 estimatedGas;
        uint256 estimatedTime;
        uint256 fee;
        bool isActive;
    }

    struct CrossChainTransfer {
        address token;
        uint256 amount;
        uint256 destinationChainId;
        address recipient;
        uint256 deadline;
        bytes routeData;
    }

    mapping(uint256 => BridgeRoute[]) public chainRoutes;
    mapping(address => bool) public authorizedBridges;
    mapping(bytes32 => bool) public processedTransfers;
    
    uint256 public protocolFee = 10; // 0.1%
    uint256 public constant MAX_FEE = 100; // 1%
    address public feeRecipient;
    
    event BridgeRouteAdded(uint256 indexed chainId, address indexed bridge);
    event BridgeRouteRemoved(uint256 indexed chainId, address indexed bridge);
    event CrossChainTransferInitiated(
        bytes32 indexed transferId,
        address indexed token,
        uint256 amount,
        uint256 destinationChainId,
        address recipient
    );
    event ProtocolFeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);

    constructor(address _feeRecipient) {
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Add a new bridge route for a specific chain
     */
    function addBridgeRoute(
        uint256 chainId,
        address bridgeContract,
        uint256 estimatedGas,
        uint256 estimatedTime,
        uint256 fee
    ) external onlyOwner {
        require(bridgeContract != address(0), "Invalid bridge contract");
        
        chainRoutes[chainId].push(BridgeRoute({
            bridgeContract: bridgeContract,
            estimatedGas: estimatedGas,
            estimatedTime: estimatedTime,
            fee: fee,
            isActive: true
        }));
        
        authorizedBridges[bridgeContract] = true;
        emit BridgeRouteAdded(chainId, bridgeContract);
    }

    /**
     * @dev Get optimal bridge route for a transfer
     */
    function getOptimalRoute(
        uint256 destinationChainId,
        uint256 amount
    ) external view returns (BridgeRoute memory optimalRoute, uint256 routeIndex) {
        BridgeRoute[] memory routes = chainRoutes[destinationChainId];
        require(routes.length > 0, "No routes available");
        
        uint256 bestScore = 0;
        uint256 bestIndex = 0;
        
        for (uint256 i = 0; i < routes.length; i++) {
            if (!routes[i].isActive) continue;
            
            // Score based on fee efficiency and speed
            uint256 score = (amount * 1000) / (routes[i].fee + routes[i].estimatedTime);
            
            if (score > bestScore) {
                bestScore = score;
                bestIndex = i;
            }
        }
        
        return (routes[bestIndex], bestIndex);
    }

    /**
     * @dev Execute cross-chain transfer with optimal routing
     */
    function executeCrossChainTransfer(
        CrossChainTransfer calldata transfer
    ) external payable nonReentrant whenNotPaused {
        require(transfer.deadline >= block.timestamp, "Transfer expired");
        require(transfer.amount > 0, "Invalid amount");
        
        bytes32 transferId = keccak256(abi.encodePacked(
            msg.sender,
            transfer.token,
            transfer.amount,
            transfer.destinationChainId,
            transfer.recipient,
            block.timestamp
        ));
        
        require(!processedTransfers[transferId], "Transfer already processed");
        processedTransfers[transferId] = true;
        
        // Calculate protocol fee
        uint256 feeAmount = (transfer.amount * protocolFee) / 10000;
        uint256 transferAmount = transfer.amount - feeAmount;
        
        // Transfer tokens from user
        IERC20(transfer.token).safeTransferFrom(
            msg.sender,
            address(this),
            transfer.amount
        );
        
        // Transfer fee to recipient
        if (feeAmount > 0) {
            IERC20(transfer.token).safeTransfer(feeRecipient, feeAmount);
        }
        
        // Get optimal route and execute bridge
        (BridgeRoute memory route,) = this.getOptimalRoute(
            transfer.destinationChainId,
            transferAmount
        );
        
        // Execute bridge transfer (implementation depends on specific bridge)
        _executeBridgeTransfer(route, transfer, transferAmount);
        
        emit CrossChainTransferInitiated(
            transferId,
            transfer.token,
            transferAmount,
            transfer.destinationChainId,
            transfer.recipient
        );
    }

    /**
     * @dev Internal function to execute bridge transfer
     */
    function _executeBridgeTransfer(
        BridgeRoute memory route,
        CrossChainTransfer calldata transfer,
        uint256 amount
    ) internal {
        require(authorizedBridges[route.bridgeContract], "Unauthorized bridge");
        
        // Approve bridge contract to spend tokens
        IERC20(transfer.token).safeApprove(route.bridgeContract, amount);
        
        // Call bridge contract (this would be specific to each bridge implementation)
        // For example: IBridge(route.bridgeContract).bridge(transfer.token, amount, transfer.destinationChainId, transfer.recipient);
    }

    /**
     * @dev Update protocol fee (only owner)
     */
    function updateProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "Fee too high");
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    /**
     * @dev Update fee recipient (only owner)
     */
    function updateFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @dev Toggle bridge route active status
     */
    function toggleBridgeRoute(
        uint256 chainId,
        uint256 routeIndex
    ) external onlyOwner {
        require(routeIndex < chainRoutes[chainId].length, "Invalid route index");
        chainRoutes[chainId][routeIndex].isActive = !chainRoutes[chainId][routeIndex].isActive;
    }

    /**
     * @dev Emergency withdrawal function
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Pause contract (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Get all routes for a chain
     */
    function getChainRoutes(uint256 chainId) external view returns (BridgeRoute[] memory) {
        return chainRoutes[chainId];
    }

    /**
     * @dev Check if transfer was processed
     */
    function isTransferProcessed(bytes32 transferId) external view returns (bool) {
        return processedTransfers[transferId];
    }
}
