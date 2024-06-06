// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title A simple Raffle Contract
 * @notice This contract is for creating a simple raffle
 * @dev Implements Chainlink VRFv2
 */
contract Raffle is VRFConsumerBaseV2, AutomationCompatibleInterface, ReentrancyGuard {
    error Raffle__NotEnoughETHSent();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);

    enum RaffleState {
        OPEN,
        CALCULATING
    }

    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    uint64 private immutable i_subscriptionId;
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    address payable[] private s_players;
    RaffleState private s_raffleState;

    event EnteredRaffle(address indexed player);
    event PickedWinner(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    /**
     * @notice Initializes the Raffle contract with the specified parameters
     * @dev Sets the initial values for the raffle, including entrance fee, interval, VRF coordinator, gas lane, subscription ID, and callback gas limit
     * @param entranceFee The fee required to enter the raffle
     * @param interval The time interval after which the raffle can pick a winner
     * @param vrfCoordinator The address of the Chainlink VRF coordinator
     * @param gasLane The key hash for the gas lane to use in the VRF request
     * @param subscriptionId The ID of the Chainlink VRF subscription
     * @param callbackGasLimit The gas limit for the callback function
     */
    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2(vrfCoordinator) {
        require(entranceFee > 0, "Entrance fee must be greater than zero");
        require(interval > 0, "Interval must be greater than zero");

        i_entranceFee = entranceFee;
        i_interval = interval;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator);
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    /**
     * @notice Allows a user to enter the raffle by sending the required entrance fee
     * @dev Adds the sender to the players array if the correct entrance fee is sent and the raffle is open
     * @dev Emits an {EnteredRaffle} event
     * @custom:requirements The sent ETH value must be at least equal to the entrance fee and the raffle must be open
     */
    function enterRaffle() external payable nonReentrant {
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughETHSent();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        s_players.push(payable(msg.sender));

        emit EnteredRaffle(msg.sender);
    }

    /**
     * @notice Checks if the upkeep is needed for the raffle
     * @dev Determines if enough time has passed, the raffle is open, the contract has a balance, and there are players in the raffle
     * @return upkeepNeeded A boolean indicating if upkeep is needed
     * @return performData An empty bytes object (not used in this implementation)
     */
    function checkUpkeep(bytes memory /* checkData */ )
    public
    view
    override
    returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        bool isOpen = RaffleState.OPEN == s_raffleState;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;

        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;

        return (upkeepNeeded, "0x0");
    }

    /**
     * @notice Performs the upkeep for the raffle if needed
     * @dev Requests random words from the Chainlink VRF coordinator to determine the raffle winner
     * @dev Emits a {RequestedRaffleWinner} event
     * @custom:requirements The upkeep must be needed as determined by {checkUpkeep}
     */
    function performUpkeep(bytes calldata /* performData */ ) external override {
        (bool upKeepNeeded,) = checkUpkeep("");
        if (!upKeepNeeded) {
            revert Raffle__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_raffleState));
        }

        s_raffleState = RaffleState.CALCULATING;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, i_subscriptionId, REQUEST_CONFIRMATIONS, i_callbackGasLimit, NUM_WORDS
        );

        emit RequestedRaffleWinner(requestId);
    }

    function fulfillRandomWords(uint256, /*requestId*/ uint256[] memory randomWords) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable winner = s_players[indexOfWinner];
        s_recentWinner = winner;
        s_raffleState = RaffleState.OPEN;
        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;
        emit PickedWinner(winner);

        (bool success,) = winner.call{value: address(this).balance}("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    /**
     * @notice Returns the entrance fee required to participate in the raffle
     * @dev This function retrieves the immutable entrance fee set during contract deployment
     * @return The entrance fee in wei
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    /**
     * @notice Returns the current state of the raffle
     * @dev This function retrieves the current raffle state which can be OPEN or CALCULATING
     * @return The current state of the raffle
     */
    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    /**
     * @notice Returns the address of a player at a given index
     * @dev This function retrieves the address of a player from the players array
     * @param playerIndex The index of the player in the players array
     * @return The address of the player at the specified index
     */
    function getPlayer(uint256 playerIndex) external view returns (address) {
        return s_players[playerIndex];
    }

    /**
     * @notice Returns the address of the most recent raffle winner
     * @dev This function retrieves the address of the last winner of the raffle
     * @return The address of the most recent winner
     */
    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    /**
     * @notice Returns the number of players currently in the raffle
     * @dev This function retrieves the length of the players array
     * @return The number of players in the raffle
     */
    function getLengthOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    /**
     * @notice Returns the timestamp of the last raffle
     * @dev This function retrieves the last timestamp when the raffle was conducted
     * @return The timestamp of the last raffle in seconds since the Unix epoch
     */
    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }
}
