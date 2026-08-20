import AppKit
import WebKit

/// `window.open` 与 `<a target="_blank">` 在 WKWebView 里默认**什么都不发生**：
/// WebKit 把这次请求交给 `WKUIDelegate.createWebViewWith`，没有 delegate（或返回 nil）就直接丢弃，
/// 页面既不报错也不跳转。力扣登录页的微信 / QQ / GitHub 按钮走的正是这条路——
/// 所以"点微信没反应"不是二维码加载失败，是弹窗根本没被创建出来。
/// Electron 版在 `main.js` 里用 `setWindowOpenHandler({action:'allow'})` 放行，这里是等价物。
@MainActor
final class WebViewPopupBridge: NSObject, WKUIDelegate, NSWindowDelegate {
    typealias CreateWebViewHandler = (
        WKWebViewConfiguration,
        WKNavigationAction,
        WKWindowFeatures
    ) -> WKWebView?

    /// 通用内容默认开独立窗口；真正的浏览器可注入处理器，
    /// 将 `target=_blank` 接管为应用内标签页。
    var createWebViewHandler: CreateWebViewHandler?
    var closeWebViewHandler: ((WKWebView) -> Bool)?

    /// 弹窗尺寸。站点给了 windowFeatures 就用它，否则给一个够放二维码的默认值；
    /// 两头都夹一下，免得某些站点报出 100×100 或者比屏幕还大的尺寸。
    static func popupSize(width: Double?, height: Double?) -> CGSize {
        CGSize(
            width: min(max(width ?? 480, 380), 1_200),
            height: min(max(height ?? 620, 420), 900)
        )
    }

    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let createWebViewHandler {
            return createWebViewHandler(configuration, navigationAction, windowFeatures)
        }

        // 必须复用回调传进来的 configuration：它携带 opener 的进程池与 websiteDataStore。
        // 自己新建一个会切断 window.opener 和 Cookie 共享，OAuth 回调就找不到发起方了。
        let size = Self.popupSize(
            width: windowFeatures.width?.doubleValue,
            height: windowFeatures.height?.doubleValue
        )
        let popup = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = navigationAction.request.url?.host ?? "外部页面"
        // 登录弹窗是从 sheet 上点出来的，不浮起来会被主窗口盖住，看着还是"没反应"。
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let key = ObjectIdentifier(popup)
        windows[key] = window
        titleObservations[key] = popup.observe(\.title, options: [.new]) { [weak window] _, change in
            guard let title = change.newValue ?? nil, !title.isEmpty else { return }
            Task { @MainActor in window?.title = title }
        }
        return popup
    }

    /// OAuth 回调页拿到票据后普遍调用 `window.close()`，不实现这个方法弹窗就永远停在那。
    func webViewDidClose(_ webView: WKWebView) {
        if closeWebViewHandler?(webView) == true { return }
        windows[ObjectIdentifier(webView)]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            let popup = window.contentView as? WKWebView
        else { return }
        let key = ObjectIdentifier(popup)
        popup.uiDelegate = nil
        titleObservations[key] = nil
        windows[key] = nil
    }

    // MARK: - JS 面板
    // 不实现这三个，页面里的 alert / confirm / prompt 同样是"静默失败"：
    // 脚本会卡在那一行，后面的登录逻辑不再往下走。

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

enum WebViewPresentation {
    /// 网页侧的悬浮滚动条。
    ///
    /// **为什么不是 `::-webkit-scrollbar`**：被样式化的滚动条在 WebKit/Chromium 里是"经典滚动条"，
    /// 会真的占掉一条布局宽度，内容跟着往里挤——那不是悬浮，是加了一根灰槽。
    /// 这里把原生滚动条彻底藏掉，自己画一颗 `position: fixed` 的胶囊浮在内容之上：
    /// 不占布局、无轨道、无边框，滚动时淡入、静止 0.9s 后淡出，与原生 `FloatingScrollIndicator` 同一口径。
    ///
    /// 用 capture 阶段监听 scroll，因此页面里**任意**滚动容器（不只是文档）都能共用这一颗 thumb。
    static let floatingScrollbarScript = """
    (() => {
      if (window.__leetcodeFloatingScrollbar) return;
      window.__leetcodeFloatingScrollbar = true;

      const THICKNESS = 6;
      const INSET = 4;
      const MINIMUM = 28;
      const FADE_DELAY = 900;

      const style = document.createElement('style');
      style.textContent = `
        html { scrollbar-width: none !important; }
        *::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
        .__lc-sb {
          position: fixed;
          z-index: 2147483647;
          border-radius: 999px;
          background: rgba(142, 142, 147, .45);
          opacity: 0;
          transition: opacity .3s ease,
            top .16s cubic-bezier(.2,.8,.3,1), left .16s cubic-bezier(.2,.8,.3,1),
            width .3s cubic-bezier(.34,1.56,.64,1), height .3s cubic-bezier(.34,1.56,.64,1);
          pointer-events: auto;
          cursor: default;
          display: none;
        }
        .__lc-sb.__lc-on { opacity: 1; }
        .__lc-sb.__lc-drag, .__lc-sb.__lc-jump { transition: opacity .3s ease; }
      `;
      (document.head || document.documentElement).appendChild(style);

      const vertical = document.createElement('div');
      const horizontal = document.createElement('div');
      vertical.className = '__lc-sb';
      horizontal.className = '__lc-sb';

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
        // thumb 是 position: fixed，**不受祖先的 overflow 裁剪**。容器有一段被上层
        // 面板盖住 / 被父级裁掉时，直接拿 getBoundingClientRect 定位就会把 thumb
        // 画到那一段上——看起来就是"滚动条跑到上一层去了"。所以先跟所有会裁剪的
        // 祖先求交集，只在真正露出来的那块里定位；交集没了就干脆不画。
        const rect = target.getBoundingClientRect();
        let top = rect.top, left = rect.left, right = rect.right, bottom = rect.bottom;
        for (let node = target.parentElement; node && node !== doc; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.overflow === 'visible' && style.overflowX === 'visible' && style.overflowY === 'visible') continue;
          const box = node.getBoundingClientRect();
          top = Math.max(top, box.top);
          left = Math.max(left, box.left);
          right = Math.min(right, box.right);
          bottom = Math.min(bottom, box.bottom);
        }
        return {
          top,
          left,
          width: Math.max(0, right - left),
          height: Math.max(0, bottom - top),
          scrollTop: target.scrollTop,
          scrollLeft: target.scrollLeft,
          scrollHeight: target.scrollHeight,
          scrollWidth: target.scrollWidth
        };
      };

      const stretchState = new WeakMap();
      const stretchFor = (target) => {
        let s = stretchState.get(target);
        if (!s) { s = { v: 0, h: 0, lastTop: null, lastLeft: null, timer: 0 }; stretchState.set(target, s); }
        return s;
      };

      /// 视口刚变过的那一小段时间：reflow 会把滚动位置夹一下，浏览器跟着抛
      /// scroll 事件，走 reveal 就等于"用户在滚动"——thumb 淡入，并带着
      /// top/left 的 0.16s 过渡从旧位置飞到新位置。拖分栏线时看到的就是这个。
      let viewportSettleUntil = 0;

      /// 落位。**横向位置一变就不许补间**：普通滚动只会改 top，left 纹丝不动；
      /// left 变了只有一个原因——容器换地方了（站点自己拖了内部分栏、面板收放、
      /// 换了滚动对象）。这时候还带着 0.16s 过渡，thumb 就会当着你的面从旧位置
      /// 飞到新位置。thumb 当前是隐藏的同理：藏着的时候位置早就过期了，
      /// 下一次淡入必须直接出现在对的地方。
      const place = (el, left, top) => {
        const snap = !el.classList.contains('__lc-on')
          || Math.abs(parseFloat(el.style.left || '0') - left) > 0.5;
        if (snap) el.classList.add('__lc-jump');
        el.style.left = left + 'px';
        el.style.top = top + 'px';
        if (!snap) return;
        requestAnimationFrame(() => {
          if (performance.now() >= viewportSettleUntil) el.classList.remove('__lc-jump');
        });
      };

      const layout = (target, s, prefetched) => {
        mount();
        // 复用 reveal 已经量过的 box：同一帧里第二次 getBoundingClientRect
        // 会再触发一次强制同步布局，重站点上这一下很贵。
        const box = prefetched || metrics(target);
        const sv = s ? s.v : 0;
        const sh = s ? s.h : 0;

        if (box.scrollHeight > box.height + 1 && box.height > 48) {
          const track = box.height - INSET * 2;
          const length = Math.min(track, Math.max(MINIMUM, track * box.height / box.scrollHeight) + sv);
          const progress = Math.min(1, Math.max(0, box.scrollTop / (box.scrollHeight - box.height)));
          const top = Math.min(box.top + INSET + (track - length) * progress, box.top + INSET + track - length);
          vertical.style.display = 'block';
          vertical.style.width = THICKNESS + 'px';
          vertical.style.height = length + 'px';
          place(vertical, box.left + box.width - THICKNESS - INSET, top);
        } else {
          vertical.style.display = 'none';
        }

        if (box.scrollWidth > box.width + 1 && box.width > 48) {
          const track = box.width - INSET * 2;
          const length = Math.min(track, Math.max(MINIMUM, track * box.width / box.scrollWidth) + sh);
          const progress = Math.min(1, Math.max(0, box.scrollLeft / (box.scrollWidth - box.width)));
          const left = Math.min(box.left + INSET + (track - length) * progress, box.left + INSET + track - length);
          horizontal.style.display = 'block';
          horizontal.style.height = THICKNESS + 'px';
          horizontal.style.width = length + 'px';
          place(horizontal, left, box.top + box.height - THICKNESS - INSET);
        } else {
          horizontal.style.display = 'none';
        }
      };

      let timer = 0;
      let activeTarget = null;
      const reveal = (target) => {
        if (performance.now() < viewportSettleUntil) {
          activeTarget = target;
          layout(target, stretchFor(target));
          return;
        }
        activeTarget = target;
        const box = metrics(target);
        const s = stretchFor(target);
        const dTop = s.lastTop == null ? 0 : Math.abs(box.scrollTop - s.lastTop);
        const dLeft = s.lastLeft == null ? 0 : Math.abs(box.scrollLeft - s.lastLeft);
        s.lastTop = box.scrollTop;
        s.lastLeft = box.scrollLeft;
        s.v = Math.min(48, s.v * 0.4 + dTop * 0.55);
        s.h = Math.min(48, s.h * 0.4 + dLeft * 0.55);
        clearTimeout(s.timer);
        s.timer = setTimeout(() => { s.v = 0; s.h = 0; layout(target, s); }, 150);
        layout(target, s, box);
        vertical.classList.add('__lc-on');
        horizontal.classList.add('__lc-on');
        clearTimeout(timer);
        timer = setTimeout(() => {
          vertical.classList.remove('__lc-on');
          horizontal.classList.remove('__lc-on');
        }, FADE_DELAY);
      };

      // **每帧最多算一次**。scroll 是 capture 阶段监听的，页面里任何容器滚动都会打到这里；
      // 直接在事件里量 rect + 写样式，等于每个 scroll 事件强制同步布局一次。
      // 百度这类页面一次滚动能打出几十个事件，主线程就是这么被拖垮的（表现为又闪又卡）。
      let pendingTarget = null;
      let frame = 0;
      const schedule = (target) => {
        pendingTarget = target;
        if (frame) return;
        frame = requestAnimationFrame(() => {
          frame = 0;
          const next = pendingTarget;
          pendingTarget = null;
          if (next) reveal(next);
        });
      };

      let drag = { current: null };
      const onDragMove = (e) => {
        if (!drag.current) return;
        e.preventDefault();
        const d = drag.current;
        const box = metrics(d.target);
        const viewport = d.vertical ? box.height : box.width;
        const content = d.vertical ? box.scrollHeight : box.scrollWidth;
        const track = viewport - INSET * 2;
        const length = Math.min(track, Math.max(MINIMUM, track * viewport / Math.max(1, content)));
        const scrollable = content - viewport;
        if (scrollable <= 0 || track <= length) return;
        const scale = scrollable / (track - length);
        const delta = (d.vertical ? e.clientY - d.startY : e.clientX - d.startX) * scale;
        const el = d.target === document || d.target === document.documentElement
          ? (document.scrollingElement || document.body)
          : d.target;
        if (d.vertical) el.scrollTop = d.startScroll + delta;
        else el.scrollLeft = d.startScroll + delta;
      };
      const endDrag = () => {
        if (drag.current) (drag.current.vertical ? vertical : horizontal).classList.remove('__lc-drag');
        drag.current = null;
        window.removeEventListener('mousemove', onDragMove);
        window.removeEventListener('mouseup', endDrag);
      };
      const startDrag = (thumb, verticalAxis) => (e) => {
        if (e.button !== 0) return;
        e.preventDefault();
        e.stopPropagation();
        const target = activeTarget || document;
        const box = metrics(target);
        drag.current = {
          vertical: verticalAxis,
          target,
          startY: e.clientY,
          startX: e.clientX,
          startScroll: verticalAxis ? box.scrollTop : box.scrollLeft
        };
        thumb.classList.add('__lc-on');
        thumb.classList.add('__lc-drag');
        window.addEventListener('mousemove', onDragMove);
        window.addEventListener('mouseup', endDrag);
      };
      vertical.addEventListener('mousedown', startDrag(vertical, true));
      horizontal.addEventListener('mousedown', startDrag(horizontal, false));

      // resize 只重排、不淡入。展开/收起列、拖分栏、缩窗口都会打到这里；
      // 走 reveal 的话用户根本没滚动，却凭空多出一条滚动条、0.9s 后才消失。
      // `__lc-jump` 期间关掉 top/left 过渡，否则视口一变 thumb 会横穿页面滑过去。
      let jumpTimer = 0;
      const relayout = () => {
        const target = activeTarget || document;
        const s = stretchFor(target);
        s.v = 0;
        s.h = 0;
        // 视口正在变（拖分栏线、缩窗口）：**先把 thumb 藏掉再重排**。
        // 只关掉 transition 不够——拖动是连续几十次 resize，每两次之间
        // transition 又被恢复，于是 thumb 一路"飞"过整个页面。
        // 藏起来重排，等下一次真正滚动时再淡入。
        vertical.classList.remove('__lc-on');
        horizontal.classList.remove('__lc-on');
        vertical.classList.add('__lc-jump');
        horizontal.classList.add('__lc-jump');
        viewportSettleUntil = performance.now() + 260;
        layout(target, s);
        clearTimeout(jumpTimer);
        jumpTimer = setTimeout(() => {
          vertical.classList.remove('__lc-jump');
          horizontal.classList.remove('__lc-jump');
        }, 150);
      };
      let resizeFrame = 0;

      document.addEventListener('scroll', (event) => schedule(event.target), true);
      window.addEventListener('resize', () => {
        if (resizeFrame) return;
        resizeFrame = requestAnimationFrame(() => {
          resizeFrame = 0;
          relayout();
        });
      }, true);
      document.addEventListener('DOMContentLoaded', mount);
      mount();
    })();
    """

    /// 只藏原生滚动条的那几行，**必须在 documentStart 就位**。
    ///
    /// 整套自绘脚本要等 DOM 建好才能挂 thumb，所以它是 documentEnd 注入的；
    /// 但藏原生滚动条等不了：样式生效之前页面是拿系统滚动条渲染的，而这台机器上
    /// 系统是 legacy 样式（接鼠标或设了"始终显示"），于是首屏明晃晃画出几条 17pt
    /// 的深灰粗条，等页面加载完才消失。这段不碰 DOM 结构，只往 documentElement
    /// 上挂一个 style，document.head 还不存在时也能跑。
    static let hideNativeScrollbarsScript = """
    (() => {
      if (window.__leetcodeHidNativeScrollbars) return;
      window.__leetcodeHidNativeScrollbars = true;
      const style = document.createElement('style');
      style.textContent = `
        html { scrollbar-width: none !important; }
        *::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
      `;
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// 注入只作用于主文档：打到第三方页面的每个 iframe（验证码、内嵌播放器）
    /// 可能破坏对方的布局脚本，而那些 iframe 的滚动条本就不该由我们接管。
    @MainActor
    static func applyFloatingScrollbars(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: hideNativeScrollbarsScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: floatingScrollbarScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }
}
