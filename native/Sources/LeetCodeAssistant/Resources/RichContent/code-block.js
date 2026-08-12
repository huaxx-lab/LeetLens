/* Shared read-only code-block contract for conversation, solution and knowledge graph. */
(() => {
  const aliases = Object.freeze({
    python3: 'python', py: 'python',
    'c++': 'cpp', 'c#': 'csharp', cs: 'csharp',
    js: 'javascript', ts: 'typescript', node: 'javascript',
    golang: 'go', objc: 'objectivec', 'objective-c': 'objectivec',
    sh: 'bash', shell: 'bash'
  });

  const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[character]));

  const requestedLanguage = info => String(info || '').trim().split(/\s+/)[0].toLowerCase();
  const canonicalLanguage = raw => {
    const requested = String(raw || '').trim().toLowerCase();
    return aliases[requested] || requested;
  };

  const highlight = (source, language) => {
    const canonical = canonicalLanguage(language);
    try {
      return canonical && window.hljs?.getLanguage(canonical)
        ? window.hljs.highlight(String(source ?? ''), { language: canonical, ignoreIllegals: true }).value
        : escapeHtml(source);
    } catch (_) {
      return escapeHtml(source);
    }
  };

  const copyButton = () => '<button class="copy" type="button" data-copy title="复制代码" aria-label="复制代码">'
    + '<span class="copy-glyph" aria-hidden="true"></span></button>';

  const fence = (source, info, attributes = '') => {
    const requested = requestedLanguage(info);
    const language = canonicalLanguage(requested);
    const suffix = attributes ? ` ${attributes}` : '';
    return `<section class="code-block"${suffix}><header class="code-head"><span>${escapeHtml(requested || 'text')}</span>`
      + `${copyButton()}</header><pre><code class="hljs${language ? ` language-${escapeHtml(language)}` : ''}">`
      + `${highlight(source, language)}</code></pre></section>`;
  };

  const codeFromButton = button => {
    const scope = button?.closest?.('.code-group') || button?.closest?.('.code-block');
    const visible = scope?.querySelector('.code-group-panel:not([hidden]) code') || scope?.querySelector('code');
    return visible?.textContent || '';
  };

  const showCopied = button => {
    if (!button) return;
    button.classList.add('copied');
    button.title = '已复制';
    window.setTimeout(() => {
      button.classList.remove('copied');
      button.title = '复制代码';
    }, 1200);
  };

  window.CodeBlock = Object.freeze({
    aliases, escapeHtml, requestedLanguage, canonicalLanguage,
    highlight, copyButton, fence, codeFromButton, showCopied
  });
})();
