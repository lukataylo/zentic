import { post } from "./post";

// Scroll reporting for the floating toolbar. Swift has no scroll view to watch
// on macOS, so the page tells it — but only when something the toolbar cares
// about changes: direction (with hysteresis, so a trackpad's jitter is not a
// flip) and the top-of-page zones.

export const HYSTERESIS = 8;
export const TOP_ZONE = 32;

export type Direction = "up" | "down";
export interface ScrollMessage {
  type: "scroll";
  y: number;
  direction: Direction;
}

export class ScrollTracker {
  private direction: Direction = "up";
  private anchor = 0;
  private zone = 0;

  update(rawY: number): ScrollMessage | null {
    const y = Math.max(0, Math.round(rawY));
    let changed = false;

    if (this.direction === "up") {
      if (y > this.anchor + HYSTERESIS) {
        this.direction = "down";
        this.anchor = y;
        changed = true;
      } else {
        this.anchor = Math.min(this.anchor, y);
      }
    } else if (y < this.anchor - HYSTERESIS) {
      this.direction = "up";
      this.anchor = y;
      changed = true;
    } else {
      this.anchor = Math.max(this.anchor, y);
    }

    const zone = y <= 0 ? 0 : y < TOP_ZONE ? 1 : 2;
    if (zone !== this.zone) {
      this.zone = zone;
      changed = true;
    }
    return changed ? { type: "scroll", y, direction: this.direction } : null;
  }
}

export function startScrollReporting(): void {
  const tracker = new ScrollTracker();
  let pending: number | null = null;
  let source: Element | null = null;

  const measure = () => {
    pending = null;
    const y = source ? source.scrollTop : window.scrollY || document.scrollingElement?.scrollTop || 0;
    const message = tracker.update(y);
    if (message) post(message);
  };

  const onScroll = (event: Event) => {
    const target = event.target;
    if (target instanceof Element && target !== document.scrollingElement && target !== document.documentElement && target !== document.body) {
      // An app that scrolls an inner container (Gmail, Notion, docs sites):
      // only one that fills most of the viewport counts as "the page".
      if (target.clientHeight < window.innerHeight * 0.6 || target.scrollHeight <= target.clientHeight + 50) return;
      source = target;
    } else {
      source = null;
    }
    if (pending === null) pending = requestAnimationFrame(measure);
  };

  document.addEventListener("scroll", onScroll, { capture: true, passive: true });
  // A navigation restores scroll position; report where we start.
  window.addEventListener("pageshow", () => {
    const message = tracker.update(window.scrollY);
    if (message) post(message);
  });
}
