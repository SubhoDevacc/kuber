import {
  type Abi,
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  http,
  type PublicClient,
  UserRejectedRequestError,
  type WalletClient,
} from "viem";
import type { Hex } from "../types";
import type { AppChain } from "./config";

/** The person's wallet in the real app: Privy's embedded wallet, or the dev key when walking headless. */
export type Signer = {
  address: Hex;
  wallet: WalletClient;
  signMessage: (message: string) => Promise<Hex>;
};

export const readClient = (c: AppChain): PublicClient =>
  createPublicClient({ chain: c.chain, transport: http(c.rpc) });

/** Contract errors in plain words. Unknown ones fall back to a generic line that still names the reason. */
const WORDS: Record<string, string> = {
  NotInvited: "You need an invite from the person who created this circle.",
  NotVerified: "Your account isn't verified yet. Finish signing up first.",
  HasOpenDebt: "You still owe money in another circle, so you can't do this.",
  AlreadyMember: "You're already a member of this circle.",
  CircleFull: "This circle is full.",
  FormingClosed: "This circle has already started, so nobody new can join.",
  NotForming: "This circle has already started.",
  AtMembershipCap: "You're in the most circles one person can be in (5).",
  LockWindow:
    "The round is closing soon, so this is locked until the next round starts.",
  SettlementPending:
    "The last round is still being closed. Try again in a minute.",
  EpochNotEnded: "This round hasn't ended yet.",
  AlreadyPaid: "You've already saved for this round.",
  NothingDue: "There's nothing to pay right now.",
  NotEnoughSaved: "You need to save for more rounds before you can do this.",
  ExceedsFreeSavings: "That's more than your savings can cover right now.",
  HasActiveLoan: "You already have a loan. Repay it first.",
  HasPendingRequest: "You already asked for a loan. Wait for it first.",
  InCooldown:
    "You repaid a loan recently. Wait a round before borrowing again.",
  InsufficientLiquidity: "The circle doesn't have enough cash for that now.",
  InvalidRepayEpochs: "Pick a shorter repayment time.",
  InvalidOfferedRate: "That interest rate isn't allowed.",
  RepayPastEnd:
    "The loan would run past the circle's last round. Pick fewer rounds.",
  OverPledged: "That's more backing than the request needs.",
  TooManyBackers: "This loan already has the most backers it can have.",
  NotPending: "This loan request isn't waiting for backers any more.",
  AlreadyVoted: "You've already voted on this.",
  VotingClosed: "Voting on this has closed.",
  ProposalOpen: "There's already an open vote on this rule.",
  NotMember: "Only members can do this.",
  NotCreator: "Only the person who created the circle can do this.",
  NothingToClaim: "There's nothing to collect yet.",
  NotEnded: "The circle hasn't ended yet.",
  AlreadyWithdrawn: "You've already collected your share-out.",
  NoActiveLoan: "You don't have a loan to repay.",
  CreatorCannotLeave: "The person who created the circle can't leave it.",
  LeavePending: "You've already asked to leave.",
  TooEarly: "It's too early for that.",
  TooFewInvites: "Invite at least 4 people.",
  InvalidStartTime: "The start time has passed. Pick a later start.",
  InvalidInvite: "One of the invites isn't valid (you can't invite yourself).",
  ERC20InsufficientAllowance:
    "The circle isn't allowed to collect enough test money. Allow more first.",
  ERC20InsufficientBalance: "You don't have enough test mUSDC.",
  ZeroAmount: "Enter an amount above zero.",
};

/** An error whose message is already fit to show. */
export class PlainError extends Error {}

export function plainReason(err: unknown): string {
  if (err instanceof PlainError) return err.message;
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError))
      return "You cancelled it, so nothing was sent.";
    const revert = err.walk(
      (e) => e instanceof ContractFunctionRevertedError,
    ) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name) return WORDS[name] ?? `The circle turned this down (${name}).`;
    if (revert)
      return "The circle turned this down right now, so nothing changed.";
    if (/insufficient funds/i.test(err.message))
      return "Your wallet has no AVAX left for the network fee.";
    if (/fetch|network|HTTP request failed|timed? ?out/i.test(err.message))
      return "Can't reach the network. Check your connection, then try again.";
  }
  return "That didn't go through. Nothing changed. Try again.";
}

export type Call = {
  address: Hex;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
};

/**
 * Simulates first (so a failing call shows the contract's reason before anything is signed), sends from the
 * person's wallet, and waits for the receipt. `onSent` fires with the hash as soon as it is broadcast.
 */
export async function sendTx(
  c: AppChain,
  signer: Signer,
  call: Call,
  onSent?: (hash: Hex) => void,
): Promise<{ hash: Hex; block: bigint }> {
  const reader = readClient(c);
  let hash: Hex;
  try {
    const { request } = await reader.simulateContract({
      account: signer.wallet.account ?? signer.address,
      address: call.address,
      abi: call.abi,
      functionName: call.functionName,
      args: call.args ?? [],
    });
    hash = await signer.wallet.writeContract({
      ...request,
      chain: c.chain,
      account: signer.wallet.account ?? signer.address,
    } as Parameters<WalletClient["writeContract"]>[0]);
  } catch (err) {
    console.error(err);
    throw new PlainError(plainReason(err));
  }
  onSent?.(hash);
  try {
    const receipt = await reader.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success")
      throw new PlainError("That didn't go through. Nothing changed.");
    return { hash, block: receipt.blockNumber };
  } catch (err) {
    console.error(err);
    throw new PlainError(
      err instanceof PlainError
        ? err.message
        : "Sent, but we couldn't confirm it yet. Check the transaction, then refresh.",
    );
  }
}
