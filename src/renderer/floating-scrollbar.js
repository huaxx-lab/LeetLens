// 悬浮滚动条：无轨道、无边框、不占布局。
//
// 为什么不用 `::-webkit-scrollbar`：被样式化的滚动条在 Chromium 里是"经典滚动条"，
// 会真的占掉一条布局宽度，内容跟着往里挤——那不是悬浮，是加了一根灰槽。
// 这里把原生滚动条藏掉，自己画一颗 position:fixed 的胶囊浮在内容之上，
// 用 capture 阶段监听 scroll，页面里任意滚动容器共用这一颗 thumb。
(() => {
  if (window.__leetcodeFloatingScrollbar) return;
  window.__leetcodeFloatingScrollbar = true;

  const THICKNESS = 6;
  const INSET = 4;
  const MINIMUM = 28;
  const FADE_DELAY = 900;

  const vertical = document.createElement('div');
  const horizontal = document.createElement('div');
  vertical.className = 'floating-scrollbar';
  horizontal.className = 'floating-scrollbar';

  const mount = () => {
    const host = document.body || document.documentElement;
    if (vertical.parentNode !== host) {
      host.appendChild(vertical);
      host.appendChild(horizontal);
    }
  };

  const metrics = (target) => {
    const doc = document.documentElement;
    if (!target || target === document || target === doc || target === document.body) {
      const body = document.body;
      return {
        top: 0,
        left: 0,
        width: window.innerWidth,
        height: window.innerHeight,
        scrollTop: window.scrollY || doc.scrollTop || 0,
        scrollLeft: window.scrollX || doc.scrollLeft || 0,
        scrollHeight: Math.max(doc.scrollHeight, body ? body.scrollHeight : 0),
        scrollWidth: Math.max(doc.scrollWidth, body ? body.scrollWidth : 0)
      };
    }
    const rect = target.getBoundingClientRect();
    return {
      top: rect.top,
      left: rect.left,
      width: rect.width,
      height: rect.height,
      scrollTop: target.scrollTop,
      scrollLeft: target.scrollLeft,
      scrollHeight: target.scrollHeight,
      scrollWidth: target.scrollWidth
    };
  };

  const layout = (target) => {
    mount();
    const box = metrics(target);

    if (box.scrollHeight > box.height + 1 && box.height > 48) {
      const track = box.height - INSET * 2;
      const length = Math.max(MINIMUM, (track * box.height) / box.scrollHeight);
      const progress = Math.min(1, Math.max(0, box.scrollTop / (box.scrollHeight - box.height)));
      vertical.style.display = 'block';
      vertical.style.width = `${THICKNESS}px`;
      vertical.style.height = `${length}px`;
      vertical.style.top = `${box.top + INSET + (track - length) * progress}px`;
      vertical.style.left = `${box.left + box.width - THICKNESS - INSET}px`;
    } else {
      vertical.style.display = 'none';
    }

    if (box.scrollWidth > box.width + 1 && box.width > 48) {
      const track = box.width - INSET * 2;
      const length = Math.max(MINIMUM, (track * box.width) / box.scrollWidth);
      const progress = Math.min(1, Math.max(0, box.scrollLeft / (box.scrollWidth - box.width)));
      horizontal.style.display = 'block';
      horizontal.style.height = `${THICKNESS}px`;
      horizontal.style.width = `${length}px`;
      horizontal.style.left = `${box.left + INSET + (track - length) * progress}px`;
      horizontal.style.top = `${box.top + box.height - THICKNESS - INSET}px`;
    } else {
      horizontal.style.display = 'none';
    }
  };

  let timer = 0;
  const reveal = (target) => {
    layout(target);
    vertical.classList.add('is-active');
    horizontal.classList.add('is-active');
    clearTimeout(timer);
    timer = setTimeout(() => {
      vertical.classList.remove('is-active');
      horizontal.classList.remove('is-active');
    }, FADE_DELAY);
  };

  // 每帧最多算一次。scroll 走的是 capture 阶段，页面里任何容器滚动都会打到这里；
  // 直接在事件里量 rect + 写样式等于每个事件强制同步布局一次，长列表滚起来会明显掉帧。
  let pendingTarget = null;
  let frame = 0;
  const schedule = target => {
    pendingTarget = target;
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const next = pendingTarget;
      pendingTarget = null;
      if (next) reveal(next);
    });
  };

  document.addEventListener('scroll', (event) => schedule(event.target), true);
  window.addEventListener('resize', () => schedule(document), true);
  document.addEventListener('DOMContentLoaded', mount);
  mount();
})();
