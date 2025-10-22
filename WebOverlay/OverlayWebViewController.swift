import AppKit
import WebKit

final class OverlayWebViewController: NSViewController, WKNavigationDelegate {
    let config: OverlayConfig
    private var webView: WKWebView!
    private var reloadTimer: Timer?

    init(config: OverlayConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        self.view = NSView(frame: NSScreen.main?.frame ?? .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let userContentController = WKUserContentController()

        // Inject a small helper that tracks timers and media so we can pause them when the system sleeps/locks.
        let pauseResumeJS = """
        window.__overlayTimers = window.__overlayTimers || { ids: [] };
        (function() {
            const _setInterval = window.setInterval;
            const _setTimeout = window.setTimeout;
            const _clearInterval = window.clearInterval;
            const _clearTimeout = window.clearTimeout;

            window.setInterval = function(fn, t) {
                const id = _setInterval(fn, t);
                try { window.__overlayTimers.ids.push(id); } catch(e) {}
                return id;
            };
            window.setTimeout = function(fn, t) {
                const id = _setTimeout(fn, t);
                try { window.__overlayTimers.ids.push(id); } catch(e) {}
                return id;
            };

            window.__overlayControl = {
                pause: function() {
                    try {
                        window.__overlayTimers.ids.forEach(function(id) { try { _clearInterval(id); _clearTimeout(id); } catch(e){} });
                        window.__overlayTimers.ids = [];
                    } catch(e) {}
                    try { document.querySelectorAll('video, audio').forEach(function(m){ try{ m.pause(); } catch(e){} }); } catch(e) {}
                },
                resume: function() {
                    // Not all timers can be restored reliably; a reload is the safest way to resume script-driven activity.
                }
            };
        })();
        """

        let userScript = WKUserScript(source: pauseResumeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContentController.addUserScript(userScript)

        let wkConfig = WKWebViewConfiguration()
        wkConfig.userContentController = userContentController
        wkConfig.suppressesIncrementalRendering = false
        wkConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: view.bounds, configuration: wkConfig)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        view.addSubview(webView)
        load()

        if let interval = config.autoReloadInterval, interval > 1 {
            reloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.webView.reload()
            }
        }
    }

    /// Pause web content: stop reload timer, call injected pause helper and hide the webview to reduce rendering.
    func pauseWebContent() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        webView.evaluateJavaScript("window.__overlayControl && window.__overlayControl.pause();", completionHandler: nil)
        webView.isHidden = true
    }

    /// Resume web content: show webview and reload to restore script-driven activity.
    func resumeWebContent() {
        webView.isHidden = false
        if let interval = config.autoReloadInterval, interval > 1 {
            reloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.webView.reload()
            }
        }
        // Reloading is the most reliable way to return to a running state.
        webView.reload()
    }

    func load() {
        let req = URLRequest(url: config.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView.load(req)
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
       injectCSS()
    }

    private func injectCSS() {
        let css = "body { background: rgba(0,0,0,0); color: white; }"
        let js = "var style=document.createElement('style');style.innerHTML=\"\(css.replacingOccurrences(of: "\"", with: "\\\""))\";document.head.appendChild(style);"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
