(() => {
  const BTN_SIZE = 26;
  const EDGE_GAP = 5;

  /** the one floating button, shared by whichever textarea is active */
  let btn = null;
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

  function ensureButton() {
    if (btn) return;
    btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'grammary-btn';
    btn.title = 'Исправить грамматику (Grammary)';
    btn.innerHTML = WAND_SVG;
    // preventDefault on mousedown keeps focus in the textarea while clicking
    btn.addEventListener('mousedown', (e) => e.preventDefault());
    btn.addEventListener('click', onClick);
    btn.addEventListener('mouseenter', cancelHide);
    btn.addEventListener('mouseleave', scheduleHide);
    document.documentElement.appendChild(btn);
  }

  function isCandidate(el) {
    return (
      el instanceof HTMLTextAreaElement &&
      !el.disabled &&
      !el.readOnly &&
      el.getClientRects().length > 0
    );
  }

  function position() {
    if (!currentTa || !btn) return;
    const r = currentTa.getBoundingClientRect();
    const tooSmall = r.width < BTN_SIZE * 2 || r.height < BTN_SIZE;
    const offScreen = r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth;
    if (tooSmall || offScreen) {
      hide(true);
      return;
    }
    btn.style.top = `${r.top + EDGE_GAP}px`;
    btn.style.left = `${r.right - EDGE_GAP - BTN_SIZE}px`;
  }

  function show(ta) {
    ensureButton();
    if (busy && currentTa !== ta) return; // don't steal the button mid-request
    cancelHide();
    currentTa = ta;
    position();
    btn.classList.add('grammary-visible');
  }

  function hide(force = false) {
    if (busy && !force) return;
    if (btn) btn.classList.remove('grammary-visible');
    currentTa = null;
  }

  function scheduleHide() {
    cancelHide();
    hideTimer = setTimeout(() => hide(), 350);
  }

  function cancelHide() {
    clearTimeout(hideTimer);
  }

  /** set value the way frameworks (React & co.) notice: native setter + input event */
  function setValue(ta, value) {
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (setter) setter.call(ta, value);
    else ta.value = value;
    ta.dispatchEvent(new Event('input', { bubbles: true }));
    ta.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function flash(cls) {
    btn.classList.add(cls);
    setTimeout(() => btn?.classList.remove(cls), 1500);
  }

  async function onClick() {
    if (busy || !currentTa) return;
    const ta = currentTa;
    const text = ta.value;
    if (!text.trim()) return;

    busy = true;
    btn.classList.add('grammary-busy');
    try {
      const resp = await chrome.runtime.sendMessage({ type: 'grammary:fix', text });
      if (!resp?.ok) throw new Error(resp?.error ?? 'пустой ответ от расширения');
      // the person may have typed meanwhile — only replace if the text is unchanged
      if (ta.value === text) {
        setValue(ta, resp.fixed);
        flash('grammary-ok');
      } else {
        btn.title = 'Grammary: текст изменился во время исправления — ничего не тронуто';
        flash('grammary-err');
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn('[grammary]', msg);
      btn.title = `Grammary: ${msg}`;
      flash('grammary-err');
      setTimeout(() => {
        if (btn) btn.title = 'Исправить грамматику (Grammary)';
      }, 8000);
    } finally {
      busy = false;
      btn.classList.remove('grammary-busy');
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
    if (e.target === currentTa && e.relatedTarget !== btn) scheduleHide();
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
