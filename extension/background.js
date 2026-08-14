const SERVER = 'http://127.0.0.1:8917';

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type !== 'grammary:fix') return;
  (async () => {
    try {
      const res = await fetch(`${SERVER}/fix`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: msg.text }),
        signal: AbortSignal.timeout(120_000),
      });
      const data = await res.json().catch(() => null);
      if (!res.ok || !data?.ok) {
        throw new Error(data?.error ?? `server answered HTTP ${res.status}`);
      }
      sendResponse({ ok: true, fixed: data.fixed });
    } catch (err) {
      // three distinct cases, not one regexp: network failure (server down),
      // client-side timeout (server alive but slow), and an error the server
      // itself reported — the last one is shown verbatim
      let error;
      if (err instanceof TypeError) {
        error = `сервер не отвечает на ${SERVER} — проверь, что Docker Desktop запущен, или выполни up.ps1 в grammary (dev-вариант: npm start в grammary/server)`;
      } else if (err?.name === 'TimeoutError') {
        error = 'сервер не ответил за 120 с — занят или завис, попробуй ещё раз';
      } else {
        error = err instanceof Error ? err.message : String(err);
      }
      sendResponse({ ok: false, error });
    }
  })();
  return true;
});
