(() => {
  const BTN_SIZE = 26;
  const BTN_GAP = 3;
  const EDGE_GAP = 5;

  /** the one floating toolbar, shared by whichever textarea is active */
  let bar = null;
  let currentTa = null;
  let busy = false;
  let hideTimer = 0;
  let rafPending = false;

  const WAND_SVG = `
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72Z"/>
      <path d="m14 7 3 3"/>
      <path d="M5 6v4"/>
      <path d="M19 14v4"/>
      <path d="M10 2v2"/>
      <path d="M7 8H3"/>
      <path d="M21 16h-4"/>
      <path d="M11 3H9"/>
    </svg>`;

  /** toolbar buttons, left to right — the wand stays rightmost, where it always was */
  const ACTIONS = [
    {
      label: 'EN',
      title: 'Перевести на английский (Grammary)',
      message: { type: 'grammary:translate', to: 'en' },
    },
    {
      label: 'RU',
      title: 'Перевести на русский (Grammary)',
      message: { type: 'grammary:translate', to: 'ru' },
    },
    {
      icon: WAND_SVG,
      title: 'Исправить грамматику (Grammary)',
      message: { type: 'grammary:fix' },
    },
  ];
  const BAR_WIDTH = ACTIONS.length * BTN_SIZE + (ACTIONS.length - 1) * BTN_GAP;

  function ensureBar() {
    if (bar) return;
    bar = document.createElement('div');
    bar.className = 'grammary-bar';
    for (const action of ACTIONS) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'grammary-btn';
      b.title = action.title;
      if (action.icon) {
        b.innerHTML = action.icon;
      } else {
        b.classList.add('grammary-lang');
        const label = document.createElement('span');
        label.textContent = action.label;
        b.appendChild(label);
      }
      b.addEventListener('click', () => onClick(action, b));
      bar.appendChild(b);
    }
    // preventDefault on mousedown keeps focus in the textarea while clicking
    bar.addEventListener('mousedown', (e) => e.preventDefault());
    bar.addEventListener('mouseenter', cancelHide);
    bar.addEventListener('mouseleave', scheduleHide);
    document.documentElement.appendChild(bar);
  }

  function isCandidate(el) {
    return (
      el instanceof HTMLTextAreaElement &&
      !el.disabled &&
      !el.readOnly &&
      el.getClientRects().length > 0
    );
  }

  /** pins the toolbar to the textarea's top-right corner; false when it can't be shown */
  function position() {
    if (!currentTa || !bar) return false;
    const r = currentTa.getBoundingClientRect();
    // the toolbar never covers more than half of the textarea's width, so a
    // narrow one gets the wand alone
    const compact = r.width < BAR_WIDTH * 2;
    const width = compact ? BTN_SIZE : BAR_WIDTH;
    const tooSmall = r.width < width * 2 || r.height < BTN_SIZE;
    const offScreen = r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth;
    if (tooSmall || offScreen) {
      hide(true);
      return false;
    }
    bar.classList.toggle('grammary-compact', compact);
    bar.style.top = `${r.top + EDGE_GAP}px`;
    bar.style.left = `${r.right - EDGE_GAP - width}px`;
    return true;
  }

  function show(ta) {
    ensureBar();
    if (busy && currentTa !== ta) return; // don't steal the toolbar mid-request
    cancelHide();
    currentTa = ta;
    if (position()) bar.classList.add('grammary-visible');
  }

  function hide(force = false) {
    if (busy && !force) return;
    if (bar) bar.classList.remove('grammary-visible');
    currentTa = null;
  }

  function scheduleHide() {
    cancelHide();
    hideTimer = setTimeout(() => hide(), 350);
  }

  function cancelHide() {
    clearTimeout(hideTimer);
  }

  /* On ntchat (Rocket.Chat) the earlier messages of the chat or thread the
     text is written into go along with it, so the model can settle doubtful
     cases (which word was meant, how a name is spelled) from the conversation. */
  const CONTEXT_HOSTS = ['ntchat.ntpayments.net'];
  const CONTEXT_MESSAGES = 20;
  const CONTEXT_CHARS = 6000;
  const CONTEXT_MESSAGE_CHARS = 1500;

  /**
   * Rocket.Chat: a message is `.rcx-message[role=listitem]` (system messages
   * are `.rcx-message-system` and thread previews in a channel are role=link,
   * so both stay out); a sequential message has no header and inherits the
   * author above it. The composer's closest ancestor holding messages is its
   * conversation: the thread panel for a reply in a thread, the room for a
   * channel message. Returns the newest messages, oldest first.
   */
  function chatContext(ta) {
    if (!CONTEXT_HOSTS.includes(location.hostname)) return undefined;
    for (let el = ta.parentElement; el && el !== document.body; el = el.parentElement) {
      const items = el.querySelectorAll('.rcx-message[role="listitem"]');
      if (items.length === 0) continue;
      const all = [];
      let author = '';
      for (const item of items) {
        const name = item.querySelector('.rcx-message-header__name');
        if (name) author = name.textContent.trim();
        const text = item.querySelector('.rcx-message-body')?.innerText.trim();
        if (text) all.push({ author, text: text.slice(0, CONTEXT_MESSAGE_CHARS) });
      }
      const picked = [];
      let chars = 0;
      for (const m of all.reverse()) {
        if (picked.length === CONTEXT_MESSAGES || chars + m.text.length > CONTEXT_CHARS) break;
        chars += m.text.length;
        picked.push(m);
      }
      return picked.reverse();
    }
    return undefined;
  }

  /** set value the way frameworks (React & co.) notice: native setter + input event */
  function setValue(ta, value) {
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (setter) setter.call(ta, value);
    else ta.value = value;
    ta.dispatchEvent(new Event('input', { bubbles: true }));
    ta.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function flash(b, cls) {
    b.classList.add(cls);
    setTimeout(() => b.classList.remove(cls), 1500);
  }

  async function onClick(action, b) {
    if (busy || !currentTa) return;
    const ta = currentTa;
    const text = ta.value;
    if (!text.trim()) return;

    busy = true;
    b.title = action.title;
    bar.classList.add('grammary-locked');
    b.classList.add('grammary-busy');
    try {
      const resp = await chrome.runtime.sendMessage({ ...action.message, text, context: chatContext(ta) });
      if (!resp?.ok) throw new Error(resp?.error ?? 'пустой ответ от расширения');
      // the person may have typed meanwhile — only replace if the text is unchanged
      if (ta.value === text) {
        setValue(ta, resp.text);
        flash(b, 'grammary-ok');
      } else {
        b.title = 'Grammary: пока шел запрос, текст изменился — ничего не тронуто';
        flash(b, 'grammary-err');
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn('[grammary]', msg);
      b.title = `Grammary: ${msg}`;
      flash(b, 'grammary-err');
      setTimeout(() => {
        b.title = action.title;
      }, 8000);
    } finally {
      busy = false;
      bar.classList.remove('grammary-locked');
      b.classList.remove('grammary-busy');
      if (currentTa) position();
      else hide();
    }
  }

  function repositionSoon() {
    if (rafPending || !currentTa) return;
    rafPending = true;
    requestAnimationFrame(() => {
      rafPending = false;
      position();
    });
  }

  document.addEventListener('mouseover', (e) => {
    if (isCandidate(e.target)) show(e.target);
  });
  document.addEventListener('mouseout', (e) => {
    if (e.target === currentTa && !bar.contains(e.relatedTarget)) scheduleHide();
  });
  document.addEventListener('focusin', (e) => {
    if (isCandidate(e.target)) show(e.target);
  });
  document.addEventListener('focusout', (e) => {
    if (e.target === currentTa) scheduleHide();
  });
  window.addEventListener('scroll', repositionSoon, { capture: true, passive: true });
  window.addEventListener('resize', repositionSoon, { passive: true });
})();
