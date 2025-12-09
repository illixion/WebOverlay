import AppKit
import WebKit

final class OverlayWebViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    let config: OverlayConfig
    private var webView: WKWebView?
    private var colorView: NSView?
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

        if config.isColorMode {
            setupColorView()
        } else {
            setupWebView()
        }
    }

    private func setupColorView() {
        guard let color = config.parsedColor else { return }

        let solidColorView = NSView(frame: view.bounds)
        solidColorView.autoresizingMask = [.width, .height]
        solidColorView.wantsLayer = true
        solidColorView.layer?.backgroundColor = color.cgColor

        view.addSubview(solidColorView)
        colorView = solidColorView
    }

    private func setupWebView() {
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
                },
                exit: function() {
                    window.webkit.messageHandlers.overlayBridge.postMessage({ action: 'exit' });
                }
            };
        })();
        """

        let userScript = WKUserScript(source: pauseResumeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContentController.addUserScript(userScript)
        userContentController.add(self, name: "overlayBridge")

        let wkConfig = WKWebViewConfiguration()
        wkConfig.userContentController = userContentController
        wkConfig.suppressesIncrementalRendering = false
        wkConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: view.bounds, configuration: wkConfig)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")

        view.addSubview(wv)
        webView = wv
        load()

        if let interval = config.autoReloadInterval, interval > 1 {
            reloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.webView?.reload()
            }
        }
    }

    /// Pause web content: stop reload timer, call injected pause helper and hide the webview to reduce rendering.
    func pauseWebContent() {
        guard !config.isColorMode else { return }
        reloadTimer?.invalidate()
        reloadTimer = nil
        webView?.evaluateJavaScript("window.__overlayControl && window.__overlayControl.pause();", completionHandler: nil)
        webView?.isHidden = true
    }

    /// Resume web content: show webview and reload to restore script-driven activity.
    func resumeWebContent() {
        guard !config.isColorMode else { return }
        webView?.isHidden = false
        if let interval = config.autoReloadInterval, interval > 1 {
            reloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.webView?.reload()
            }
        }
        // Reloading is the most reliable way to return to a running state.
        webView?.reload()
    }

    func load() {
        guard let url = config.url else { return }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView?.load(req)
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
       injectCSS()
    }

    private func injectCSS() {
        let css = "body { background: rgba(0,0,0,0); color: white; }"
        let js = "var style=document.createElement('style');style.innerHTML=\"\(css.replacingOccurrences(of: "\"", with: "\\\""))\";document.head.appendChild(style);"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        if action == "exit" {
            NSApplication.shared.terminate(nil)
        }
    }
}
