// End-user recording opt-out, checked before rrweb starts so an opted-out user
// produces no events and no network requests. The signal is a cookie or a
// localStorage key named by the server-supplied `optOutCookieName`; localStorage
// is checked too because cookies are not sent on cross-origin events requests.

const TRUTHY = (value) =>
  value != null && value !== "" && value !== "0" && value !== "false";

function cookieValue(name, doc) {
  const cookies = (doc.cookie || "").split(";");
  for (const pair of cookies) {
    const idx = pair.indexOf("=");
    const key = (idx === -1 ? pair : pair.slice(0, idx)).trim();
    if (key === name) {
      return decodeURIComponent(pair.slice(idx + 1).trim());
    }
  }
  return null;
}

function storageValue(name, storage) {
  try {
    return storage.getItem(name);
  } catch {
    return null;
  }
}

export function hasOptedOut(
  name,
  doc = globalThis.document,
  storage = globalThis.localStorage,
) {
  if (!name) return false;
  return TRUTHY(cookieValue(name, doc)) || TRUTHY(storageValue(name, storage));
}

export function optOut(
  name,
  doc = globalThis.document,
  storage = globalThis.localStorage,
) {
  if (!name) return;
  doc.cookie = `${name}=1; path=/; max-age=31536000; SameSite=Lax`;
  try {
    storage.setItem(name, "1");
  } catch {
    // localStorage may be unavailable (e.g. private mode); the cookie suffices.
  }
}

export function optIn(
  name,
  doc = globalThis.document,
  storage = globalThis.localStorage,
) {
  if (!name) return;
  doc.cookie = `${name}=; path=/; max-age=0; SameSite=Lax`;
  try {
    storage.removeItem(name);
  } catch {
    // ignore
  }
}
