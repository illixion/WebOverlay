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
        let wkConfig = WKWebViewConfiguration()
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
