import { test } from "node:test";
import assert from "node:assert/strict";

import { fetchAllEvents } from "../src/dashboard/events.js";

// Serves `pages` in order, one per fetch call, recording each requested URL.
function fakeFetch(pages, requestedUrls) {
  let call = 0;
  return (url) => {
    requestedUrls.push(url);
    const page = pages[Math.min(call++, pages.length - 1)];
    return Promise.resolve({ ok: true, json: () => Promise.resolve(page) });
  };
}

function events(count, startTs) {
  return Array.from({ length: count }, (_, i) => ({ type: 3, timestamp: startTs + i }));
}

// The server's page size is configurable (max_events_per_page) and can be
// SMALLER than the dashboard's PAGE_SIZE constant — 500 on L'Europeo prod.
// The old stop test `events.length < PAGE_SIZE` then ended pagination after
// the first page and permanently truncated every long replay at 500 events.
// Pagination must continue until an empty page, whatever the server returns.
test("fetchAllEvents paginates past a server page smaller than PAGE_SIZE", async () => {
  const urls = [];
  const savedFetch = Object.getOwnPropertyDescriptor(globalThis, "fetch");
  Object.defineProperty(globalThis, "fetch", {
    value: fakeFetch([events(500, 1000), events(500, 2000), []], urls),
    configurable: true,
    writable: true,
  });
  try {
    const all = await new Promise((resolve, reject) => {
      fetchAllEvents("/api/sessions/s/windows/w/events", (err, evts) => {
        if (err) reject(err);
        else resolve(evts);
      });
    });
    assert.equal(all.length, 1000);
    assert.equal(urls.length, 3);
    assert.match(urls[1], /after=1499/);
    assert.match(urls[2], /after=2499/);
  } finally {
    if (savedFetch) Object.defineProperty(globalThis, "fetch", savedFetch);
    else delete globalThis.fetch;
  }
});
