// Keeping a lens true as a feed grows.
//
// A `filter` or `reorder` op runs once at DOM ready, and on a timeline that is
// the first twenty cards. Everything the user scrolls to afterwards arrives
// unfiltered, so the lens looks like it stopped working halfway down the page —
// which is worse than never having applied, because the user has already stopped
// checking.
//
// So each region carrying a live op gets its own `MutationObserver`. Scoped to
// that region, not the document: a page-wide observer on a modern app fires
// thousands of times a minute, and the callback would spend more of the frame
// than the ops it exists to re-run.
//
// ## The two ways this could go wrong, and what stops each
//
// **Self-triggering.** Our own re-pass mutates the subtree we are watching, and
// mutation records are delivered as a microtask *after* the pass returns — so a
// simple "am I busy" flag is already false by the time our own records arrive,
// and the observer would schedule itself forever. The fix is `takeRecords()`:
// after a pass, the queue is drained and discarded, so the mutations we caused
// are consumed before they can be delivered. Record filtering is kept as well,
// for the mutations the engine makes outside a pass.
//
// Draining *every* watch rather than the one that fired is what makes that hold
// on a real page. Regions nest — a feed inside a column, a column inside a
// main — and `subtree: true` means an ancestor's observer sees every mutation a
// descendant's pass makes. Draining only the firing watch left those records
// queued, so our own work woke the ancestor, whose pass mutated the descendant,
// whose observer had not been drained either: two nested regions ping-ponged at
// the rate cap for as long as the tab stayed open.
//
// But draining *everything* discards the page's work along with ours. A pass only
// ever writes inside its own region, so a watch on a disjoint region cannot be
// holding a record of what we did — everything queued there is the site's, and
// emptying it lost a real mutation that nothing came back for. Self-correcting on
// an infinite feed, where another card is along in a moment, and permanent for a
// region that changes once. So the drain is scoped to the watches that overlap
// the region the pass touched, which is precisely the set that can see our work.
//
// **Cost.** A site that streams content can mutate continuously. Passes are
// debounced, hard-capped per second, and each processes at most
// `lensMaxItemsPerPass` items (enforced in the op runner). When the cap is hit
// the pass is deferred to the next window rather than dropped, because a deferred
// pass still catches up and a dropped one leaves cards unfiltered forever.

export interface ObserverBudget {
  /** `Budget.lensObserverDebounce`. */
  debounceMs: number;
  /** `Budget.lensObserverMaxPassesPerSecond`. */
  maxPassesPerSecond: number;
}

export const DEFAULT_OBSERVER_BUDGET: ObserverBudget = {
  debounceMs: 80,
  maxPassesPerSecond: 8,
};

/** Prefix on every attribute and element name this engine writes into a page. */
const OURS = "zentic-lens";

interface Watch {
  target: Element;
  observer: MutationObserver;
  timer: ReturnType<typeof setTimeout> | undefined;
}

/**
 * The set of live observers for the currently applied lenses.
 *
 * One instance per applied lens set, torn down wholesale by `disconnectAll()` —
 * which `LensEngine.clear()` and every SPA navigation call, because an observer
 * left watching a region that no longer exists is a leak that survives until the
 * tab closes.
 */
export class LensObservers {
  private readonly watches: Watch[] = [];
  private passes: number[] = [];

  constructor(
    private readonly budget: ObserverBudget,
    /** Re-runs the live ops for one region. Must be synchronous, so `drain()`
     * can consume the records it produced before they are delivered. */
    private readonly rerun: (target: Element) => void,
    private readonly now: () => number = () => Date.now(),
    private readonly schedule: (fn: () => void, ms: number) => ReturnType<typeof setTimeout> = (
      fn,
      ms,
    ) => setTimeout(fn, ms),
  ) {}

  get count(): number {
    return this.watches.length;
  }

  /** Watch one region. Watching the same element twice is a no-op — two observers
   * on one feed would double every pass and halve the rate cap. */
  watch(target: Element): void {
    if (this.watches.some((watch) => watch.target === target)) return;

    // The callback finds its own watch by target rather than closing over the
    // record, so a disconnected region simply schedules nothing.
    const observer = new MutationObserver((records) => {
      if (!records.some(isPageMutation)) return;
      const watch = this.watches.find((entry) => entry.target === target);
      if (watch) this.scheduleFor(watch);
    });

    // `childList` and `subtree` only. Attribute mutations are how *we* hide an
    // item, so not observing them removes the largest source of self-triggering
    // before it starts — and a feed growing is always a childList change.
    try {
      observer.observe(target, { childList: true, subtree: true });
    } catch {
      // A detached or non-Element target. Nothing to watch; the initial pass has
      // already applied, so the lens is correct, just not live.
      return;
    }

    this.watches.push({ target, observer, timer: undefined });
  }

  /**
   * Discard mutations produced by our own work.
   *
   * Called by the engine immediately after any pass it runs. This is the load-
   * bearing half of the self-trigger guard: without it, a `reorder` moving site
   * nodes would queue records indistinguishable from the site moving them.
   *
   * `within` names the subtree the pass touched, and limits the drain to the
   * watches that could have seen it — the target itself, its ancestors (whose
   * `subtree: true` catches every descendant mutation) and its descendants. A
   * watch on a disjoint region cannot hold a record of our work, so everything it
   * holds is the page's; draining it discarded a genuine mutation and nothing
   * ever came back for it. That is not hypothetical timing: a custom element
   * reacting to a `reorder` runs its `connectedCallback` synchronously, inside our
   * pass, and can update a widget in another column as it does.
   *
   * Omit `within` for a whole-document pass, where everything is ours.
   */
  drain(within?: Element): void {
    for (const watch of this.watches) {
      if (within && !overlaps(watch.target, within)) continue;
      watch.observer.takeRecords();
    }
  }

  /**
   * Stop watching everything.
   *
   * The sliding rate window deliberately survives. It is a budget on *this
   * second of this tab's main thread*, and a router that navigates on every
   * click calls this on every click — clearing the window there handed the next
   * route a full allowance immediately, so the cap that exists to stop a lens
   * making a page janky could be lifted simply by navigating quickly.
   */
  disconnectAll(): void {
    for (const watch of this.watches) {
      if (watch.timer !== undefined) clearTimeout(watch.timer);
      watch.observer.disconnect();
    }
    this.watches.length = 0;
  }

  private scheduleFor(entry: Watch): void {
    if (entry.timer !== undefined) return;

    entry.timer = this.schedule(() => {
      entry.timer = undefined;
      this.runPass(entry);
    }, this.budget.debounceMs);
  }

  /**
   * Run one pass, unless the rate cap says not yet.
   *
   * The cap is a sliding window rather than a fixed interval, so a burst cannot
   * borrow quota from a quiet second and land eight passes in one frame.
   */
  private runPass(entry: Watch): void {
    const now = this.now();
    this.passes = this.passes.filter((at) => now - at < 1000);

    if (this.passes.length >= this.budget.maxPassesPerSecond) {
      const oldest = this.passes[0] ?? now;
      const wait = Math.max(1, 1000 - (now - oldest));
      entry.timer = this.schedule(() => {
        entry.timer = undefined;
        this.runPass(entry);
      }, wait);
      return;
    }

    this.passes.push(now);

    try {
      this.rerun(entry.target);
    } catch {
      // A re-pass that throws must not take the observer down with it: the next
      // batch of cards still deserves filtering.
    } finally {
      // Consume what we just caused, before the microtask that would deliver it —
      // across every watch our work could have reached, not just this one. An
      // ancestor region observing a subtree sees the descendant's pass as a page
      // mutation and would schedule a pass of its own, which mutates the
      // descendant right back. A pass only ever writes inside its own region, so
      // that is exactly the overlapping watches and no more.
      this.drain(entry.target);
    }
  }
}

/** Could a mutation inside `within` have been recorded by a watch on `target`?
 * True for the same element and for either containing the other — an observer is
 * `subtree: true`, so an ancestor sees everything below it. */
function overlaps(target: Element, within: Element): boolean {
  return target === within || target.contains(within) || within.contains(target);
}

/** True when a record describes the *page* changing rather than us changing it. */
function isPageMutation(record: MutationRecord): boolean {
  if (record.type === "attributes") {
    return !(record.attributeName ?? "").startsWith(`data-${OURS}`);
  }

  const nodes = [...Array.from(record.addedNodes), ...Array.from(record.removedNodes)];
  if (nodes.length === 0) return false;
  return nodes.some((node) => !isOurNode(node));
}

function isOurNode(node: Node): boolean {
  const element = node as Element;
  return typeof element.localName === "string" && element.localName.startsWith(OURS);
}
