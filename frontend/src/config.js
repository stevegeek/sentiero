import { hasOptedOut } from "./opt_out.js";

// Two independent signals suppress recording, both treated identically:
//   - an explicit opt-out cookie/localStorage key (see opt_out.js), and
//   - the browser's Global Privacy Control signal, when respect_gpc is enabled.
export function shouldRecord(config, nav = globalThis.navigator) {
  if (hasOptedOut(config?.optOutCookieName)) return false;
  if (config?.respectGpc && nav?.globalPrivacyControl) return false;
  return true;
}
