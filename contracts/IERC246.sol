// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC246
 * @dev Interface for the ERCX governance token with proposal and voting functionality.
 */
interface IERC246 {

    /**
     * @notice Create a new proposal with multiple function calls.
     * @param _targets The target contract addresses for the proposal.
     * @param _data The encoded function calls (signature + parameters) to be executed if the proposal passes.
     * @param _values The amount of Ether to send with each function call.
     * @param _votingDurationInBlocks The duration (in blocks) for which the proposal will be open for voting.
     */
    function createProposal(string memory title, address[] memory _targets, bytes[] memory _data, uint256[] memory _values, uint256 _votingDurationInBlocks) external;

    /**
     * @notice Vote on an active proposal.
     * @param _proposalId The ID of the proposal to vote on.
     * @param _support A boolean indicating whether the vote is in favor (true) or against (false).
     */
    function vote(uint256 _proposalId, bool _support) external;

    /**
     * @notice Enqueue a proposal for execution after voting ends.
     * @param _proposalId The ID of the proposal to enqueue.
     */
    function enqueueProposal(uint256 _proposalId) external;

    /**
     * @notice Execute the proposal if the voting period has ended and the proposal passed.
     * @param _proposalId The ID of the proposal to execute.
     */
    function executeProposal(uint256 _proposalId) external;

    /**
     * @notice Allows the proposer or governance to delete a proposal.
     * @param _proposalId The ID of the proposal to delete.
     */
    function deleteProposal(uint256 _proposalId) external;

    /**
     * @notice Get the current voting outcome of a proposal.
     * @param _proposalId The ID of the proposal to check.
     * @return votesFor The total votes in favor of the proposal.
     * @return votesAgainst The total votes against the proposal.
     */
    function getProposalCurrentOutcome(uint256 _proposalId) external view returns (uint256 votesFor, uint256 votesAgainst);

    /**
     * @notice Event emitted when a new proposal is created.
     * @param proposalId The ID of the proposal.
     * @param targets The target contract addresses.
     * @param data The encoded function calls.
     * @param values The amount of Ether to send with each function call.
     * @param deadlineBlock The block number at which voting will end.
     */
    event ProposalCreated(uint256 indexed proposalId, address[] targets, bytes[] data, uint256[] values, uint256 deadlineBlock);

    /**
     * @notice Event emitted when a vote is cast.
     * @param voter The address of the voter.
     * @param proposalId The ID of the proposal.
     * @param support Whether the vote was in favor or against the proposal.
     */
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support);

    /**
     * @notice Event emitted when a proposal is enqueued for execution.
     * @param proposalId The ID of the proposal.
     * @param accepted Whether the proposal was accepted (true) or rejected (false).
     */
    event ProposalEnqueued(uint256 indexed proposalId, bool indexed accepted);

    /**
     * @notice Event emitted when a proposal is executed.
     * @param proposalId The ID of the proposal.
     * @param accepted Whether the proposal was accepted (true) or rejected (false).
     */
    event ProposalExecuted(uint256 indexed proposalId, bool indexed accepted);

    /**
     * @notice Event emitted when a proposal is rejected.
     * @param proposalId The ID of the proposal.
     */
    event ProposalRejected(uint256 indexed proposalId);

    /**
     * @notice Event emitted when a proposal is deleted.
     * @param proposalId The ID of the proposal.
     */
    event ProposalDeleted(uint256 indexed proposalId);
}
