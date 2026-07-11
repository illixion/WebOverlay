import AppKit
import WebKit

/// The content a controller renders.
enum OverlayContent {
    case page(Page, autoReloadInterval: TimeInterval?, unloadWhenHidden: Bool)
    case lockScreen(GlobalSettings)

    var isLockScreen: Bool { if case .lockScreen = self { return true } else { return false } }
    var isColorMode: Bool { if case .page(let p, _, _) = self { return p.isColorMode } else { return false } }
    var url: URL? { if case .page(let p, _, _) = self { return p.url } else { return nil } }
    var parsedColor: NSColor? { if case .page(let p, _, _) = self { return p.parsedColor } else { return nil } }
    var autoReloadInterval: TimeInterval? { if case .page(_, let i, _) = self { return i } else { return nil } }
    /// Whether to fully unload the page (about:blank) while hidden, reloading on show.
    var unloadWhenHidden: Bool { if case .page(_, _, let u) = self { return u } else { return false } }
}

final class OverlayWebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private(set) var content: OverlayContent
    private var webView: WKWebView?
    private var colorView: NSView?
    private var reloadTimer: Timer?

    /// Invoked when the lock screen password is verified. If nil, the app terminates.
    var onUnlockSuccess: (() -> Void)?

    /// Invoked after content is (re)built, so the owner can restore overlays (e.g. a drag catcher).
    var onContentRebuilt: (() -> Void)?

    init(content: OverlayContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        self.view = NSView(frame: NSScreen.main?.frame ?? .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildContent()
    }

    private func buildContent() {
        if content.isLockScreen {
            setupLockScreenView()
        } else if content.isColorMode {
            setupColorView()
        } else {
            setupWebView()
        }
    }

    /// Swap the rendered content in place without recreating the host window.
    ///
    /// The window must never be destroyed/recreated to change a page's URL: a
    /// window created while the app is temporarily `.regular` (e.g. the Manage
    /// Pages window is open) loses its ability to float over other apps'
    /// full-screen spaces, and flipping back to `.accessory` doesn't restore it.
    /// Reloading in the original window preserves that behavior.
    func setContent(_ newContent: OverlayContent) {
        reloadTimer?.invalidate()
        reloadTimer = nil
        colorView?.removeFromSuperview()
        colorView = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil

        content = newContent
        buildContent()
        onContentRebuilt?()
    }

    private func setupColorView() {
        guard let color = content.parsedColor else { return }

        let solidColorView = NSView(frame: view.bounds)
        solidColorView.autoresizingMask = [.width, .height]
        solidColorView.wantsLayer = true
        solidColorView.layer?.backgroundColor = color.cgColor

        view.addSubview(solidColorView)
        colorView = solidColorView
    }

    private func setupLockScreenView() {
        let userContentController = WKUserContentController()

        // Bridge to Swift - password verification happens in Swift, not JavaScript
        // This API is available to both built-in and custom lock screens
        let bridgeJS = """
        window.__overlayControl = {
            verifyPassword: function(password) {
                window.webkit.messageHandlers.overlayBridge.postMessage({ action: 'verifyPassword', password: password });
            },
            exit: function() {
                window.webkit.messageHandlers.overlayBridge.postMessage({ action: 'exit' });
            }
        };
        """
        let userScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContentController.addUserScript(userScript)
        userContentController.add(self, name: "overlayBridge")

        let wkConfig = WKWebViewConfiguration()
        wkConfig.userContentController = userContentController
        wkConfig.suppressesIncrementalRendering = false

        let wv = WKWebView(frame: view.bounds, configuration: wkConfig)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")

        view.addSubview(wv)
        webView = wv

        // If a URL is specified, load it instead of the built-in lock screen
        if let url = content.url {
            NSLog("[Overlay] Lock screen mode with custom URL: \(url)")
            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            wv.load(req)
        } else {
            // Use built-in lock screen HTML
            let lockScreenHTML = buildBuiltInLockScreenHTML()
            wv.loadHTMLString(lockScreenHTML, baseURL: nil)
        }
    }

    private func buildBuiltInLockScreenHTML() -> String {
        let lockScreenConfig: FakeLockScreenConfig
        if case .lockScreen(let globals) = content {
            lockScreenConfig = globals.fakeLockScreen ?? .default
        } else {
            lockScreenConfig = .default
        }
        let message = lockScreenConfig.message ?? ""
        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        // Password is NOT embedded in HTML - validation happens in Swift
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                    user-select: none;
                    -webkit-user-select: none;
                }
                html, body {
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
                    background: rgba(0, 0, 0, 0.55);
                    color: white;
                }
                .container {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    height: 100%;
                    padding: 20px;
                }
                .time {
                    font-size: 96px;
                    font-weight: 200;
                    letter-spacing: -2px;
                    margin-bottom: 8px;
                    text-shadow: 0 2px 20px rgba(0, 0, 0, 0.5);
                }
                .date {
                    font-size: 24px;
                    font-weight: 400;
                    opacity: 0.9;
                    margin-bottom: 60px;
                    text-shadow: 0 1px 10px rgba(0, 0, 0, 0.5);
                }
                .prompt-hint {
                    font-size: 16px;
                    opacity: 0.6;
                    transition: opacity 0.3s ease;
                }
                .prompt-hint.hidden {
                    opacity: 0;
                    pointer-events: none;
                    position: absolute;
                }
                .unlock-panel {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    opacity: 0;
                    transform: translateY(10px);
                    transition: opacity 0.25s ease, transform 0.25s ease;
                    pointer-events: none;
                    overflow: hidden;
                    max-height: 0;
                }
                .unlock-panel.visible {
                    opacity: 1;
                    transform: translateY(0);
                    pointer-events: auto;
                    max-height: 200px;
                }
                .avatar {
                    width: 80px;
                    height: 80px;
                    border-radius: 50%;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    margin-bottom: 12px;
                    font-size: 36px;
                }
                .username {
                    font-size: 18px;
                    font-weight: 500;
                    margin-bottom: 16px;
                }
                .password-container {
                    position: relative;
                    width: 220px;
                }
                .password-input {
                    width: 100%;
                    height: 36px;
                    padding: 0 40px 0 16px;
                    border: none;
                    border-radius: 18px;
                    background: rgba(255, 255, 255, 0.15);
                    backdrop-filter: blur(10px);
                    -webkit-backdrop-filter: blur(10px);
                    color: white;
                    font-size: 16px;
                    outline: none;
                    caret-color: white;
                }
                .password-input::placeholder {
                    color: rgba(255, 255, 255, 0.5);
                }
                .password-input:focus {
                    background: rgba(255, 255, 255, 0.2);
                }
                .password-input:disabled {
                    opacity: 0.5;
                }
                .submit-btn {
                    position: absolute;
                    right: 4px;
                    top: 50%;
                    transform: translateY(-50%);
                    width: 28px;
                    height: 28px;
                    border: none;
                    border-radius: 50%;
                    background: rgba(255, 255, 255, 0.2);
                    color: white;
                    cursor: pointer;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 14px;
                    opacity: 0.7;
                    transition: opacity 0.2s;
                }
                .submit-btn:hover {
                    opacity: 1;
                }
                .submit-btn:disabled {
                    opacity: 0.3;
                    cursor: not-allowed;
                }
                .message {
                    position: fixed;
                    bottom: 40px;
                    left: 50%;
                    transform: translateX(-50%);
                    font-size: 14px;
                    opacity: 0.7;
                    text-align: center;
                    max-width: 80%;
                    white-space: pre-wrap;
                    text-shadow: 0 1px 6px rgba(0, 0, 0, 0.5);
                }
                .shake {
                    animation: shake 0.5s ease-in-out;
                }
                @keyframes shake {
                    0%, 100% { transform: translateX(0); }
                    20%, 60% { transform: translateX(-10px); }
                    40%, 80% { transform: translateX(10px); }
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="time" id="time">00:00</div>
                <div class="date" id="date">Loading...</div>
                <div class="prompt-hint" id="prompt-hint">Press any key to unlock</div>
                <div class="unlock-panel" id="unlock-panel">
                    <div class="avatar">🔒</div>
                    <div class="username">Locked</div>
                    <div class="password-container" id="password-container">
                        <input type="password" class="password-input" id="password" placeholder="Enter Password" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                        <button class="submit-btn" id="submit">→</button>
                    </div>
                </div>
            </div>
            <div class="message" id="message"></div>
            <script>
                const MESSAGE = "\(escapedMessage)";
                const DISMISS_DELAY = 10000;

                document.getElementById('message').textContent = MESSAGE;

                function updateTime() {
                    const now = new Date();
                    const hours = now.getHours();
                    const minutes = now.getMinutes().toString().padStart(2, '0');
                    document.getElementById('time').textContent = hours + ':' + minutes;

                    const options = { weekday: 'long', month: 'long', day: 'numeric' };
                    document.getElementById('date').textContent = now.toLocaleDateString('en-US', options);
                }
                updateTime();
                setInterval(updateTime, 1000);

                const passwordInput = document.getElementById('password');
                const passwordContainer = document.getElementById('password-container');
                const submitBtn = document.getElementById('submit');
                const unlockPanel = document.getElementById('unlock-panel');
                const promptHint = document.getElementById('prompt-hint');

                let panelVisible = false;
                let dismissTimer = null;
                let verifying = false;

                function showPanel() {
                    if (panelVisible) return;
                    panelVisible = true;
                    unlockPanel.classList.add('visible');
                    promptHint.classList.add('hidden');
                    setTimeout(() => passwordInput.focus(), 50);
                    resetDismissTimer();
                }

                function hidePanel() {
                    if (!panelVisible || verifying) return;
                    panelVisible = false;
                    unlockPanel.classList.remove('visible');
                    promptHint.classList.remove('hidden');
                    passwordInput.value = '';
                    passwordInput.blur();
                    clearDismissTimer();
                }

                function resetDismissTimer() {
                    clearDismissTimer();
                    dismissTimer = setTimeout(hidePanel, DISMISS_DELAY);
                }

                function clearDismissTimer() {
                    if (dismissTimer) {
                        clearTimeout(dismissTimer);
                        dismissTimer = null;
                    }
                }

                function checkPassword() {
                    const pwd = passwordInput.value;
                    if (!pwd) return;

                    verifying = true;
                    clearDismissTimer();
                    passwordInput.disabled = true;
                    submitBtn.disabled = true;

                    window.__overlayControl.verifyPassword(pwd);
                }

                // Called from Swift when password is incorrect
                window.onPasswordIncorrect = function() {
                    verifying = false;
                    passwordInput.value = '';
                    passwordInput.disabled = false;
                    submitBtn.disabled = false;
                    passwordContainer.classList.add('shake');
                    setTimeout(() => {
                        passwordContainer.classList.remove('shake');
                        passwordInput.focus();
                    }, 500);
                    resetDismissTimer();
                };

                passwordInput.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter') {
                        checkPassword();
                    } else {
                        resetDismissTimer();
                    }
                });

                submitBtn.addEventListener('click', function() {
                    checkPassword();
                    resetDismissTimer();
                });

                // Any keypress on the body shows the panel or dismisses it with Escape
                document.addEventListener('keydown', function(e) {
                    if (e.key === 'Escape') {
                        hidePanel();
                        return;
                    }
                    if (!panelVisible) {
                        if (e.metaKey || e.ctrlKey || e.altKey) return;
                        showPanel();
                    }
                });

                // Mouse click anywhere shows the panel or refocuses input
                document.addEventListener('mousedown', function(e) {
                    if (!panelVisible) {
                        showPanel();
                    } else if (e.target !== passwordInput && e.target !== submitBtn && !passwordInput.disabled) {
                        passwordInput.focus();
                        resetDismissTimer();
                    }
                });
            </script>
        </body>
        </html>
        """
    }

    private func setupWebView() {
        let userContentController = WKUserContentController()

        // Inject a small helper that tracks timers and media so we can pause them when the system sleeps/locks,
        // and that drives the standard Page Visibility API so pages can idle backend work while invisible.
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

            // --- Page Visibility integration ---------------------------------
            // The overlay is a borderless window WebKit doesn't reliably report as
            // hidden, so we drive visibility explicitly. We override document.hidden /
            // document.visibilityState (they're configurable on the prototype, so an
            // own property on `document` shadows them) and dispatch a real
            // 'visibilitychange' event plus a custom 'overlayvisibilitychange' detail.
            let __overlayVisible = true;
            try {
                Object.defineProperty(document, 'visibilityState', {
                    configurable: true, get: function() { return __overlayVisible ? 'visible' : 'hidden'; }
                });
                Object.defineProperty(document, 'hidden', {
                    configurable: true, get: function() { return !__overlayVisible; }
                });
            } catch(e) {}

            function __overlaySetVisible(visible) {
                visible = !!visible;
                if (visible === __overlayVisible) return;
                __overlayVisible = visible;
                try { document.dispatchEvent(new Event('visibilitychange')); } catch(e) {}
                try { window.dispatchEvent(new Event(visible ? 'focus' : 'blur')); } catch(e) {}
                try { document.dispatchEvent(new CustomEvent('overlayvisibilitychange', { detail: { visible: visible } })); } catch(e) {}
            }

            window.__overlayControl = {
                setVisible: __overlaySetVisible,
                pause: function() {
                    __overlaySetVisible(false);
                    try {
                        window.__overlayTimers.ids.forEach(function(id) { try { _clearInterval(id); _clearTimeout(id); } catch(e){} });
                        window.__overlayTimers.ids = [];
                    } catch(e) {}
                    try { document.querySelectorAll('video, audio').forEach(function(m){ try{ m.pause(); } catch(e){} }); } catch(e) {}
                },
                resume: function() {
                    // Timers aren't restored (a reload is used for that); just flip visibility back.
                    __overlaySetVisible(true);
                },
                exit: function() {
                    window.webkit.messageHandlers.overlayBridge.postMessage({ action: 'exit' });
                }
            };
        })();
        """

        let userScript = WKUserScript(source: pauseResumeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContentController.addUserScript(userScript)

        // Force a transparent background from the very first paint so the page's
        // default (usually white) body never flashes through the overlay.
        let transparentBGJS = """
        (function() {
            var style = document.createElement('style');
            style.textContent = 'html,body{background:transparent !important;}';
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        let bgScript = WKUserScript(source: transparentBGJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(bgScript)

        userContentController.add(self, name: "overlayBridge")

        let wkConfig = WKWebViewConfiguration()
        wkConfig.userContentController = userContentController
        wkConfig.suppressesIncrementalRendering = false
        wkConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: view.bounds, configuration: wkConfig)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.underPageBackgroundColor = .clear  // avoid the default white backstop flashing during loads

        view.addSubview(wv)
        webView = wv
        load()

        if let interval = content.autoReloadInterval, interval > 1 {
            reloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.webView?.reload()
            }
        }
    }

    /// Pause web content: stop reload timer and signal/unload the page while hidden.
    func pauseWebContent() {
        guard !content.isColorMode else { return }
        reloadTimer?.invalidate()
        reloadTimer = nil
        if content.unloadWhenHidden {
            // Fully unload: drop the document so it can't poll/fetch or hold memory.
            webView?.load(URLRequest(url: URL(string: "about:blank")!))
        } else {
            // Keep the page loaded; the Page Visibility shim lets it idle its own work.
            webView?.evaluateJavaScript("window.__overlayControl && window.__overlayControl.pause();", completionHandler: nil)
        }
        webView?.isHidden = true
    }

    /// Resume web content: show the webview and either reload (if it was unloaded) or just flip visibility.
    func resumeWebContent() {
        guard !content.isColorMode else { return }
        webView?.isHidden = false
        if let interval = content.autoReloadInterval, interval > 1 {
            reloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.webView?.reload()
            }
        }
        if content.unloadWhenHidden {
            // The document was discarded while hidden, so reload the configured URL.
            load()
        } else {
            webView?.evaluateJavaScript("window.__overlayControl && window.__overlayControl.resume();", completionHandler: nil)
        }
    }

    func load() {
        guard let url = content.url else { return }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView?.load(req)
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only inject CSS for non-lock-screen mode
        if !content.isLockScreen {
            injectCSS()
        }
    }

    private func injectCSS() {
        let css = "body { background: rgba(0,0,0,0); color: white; }"
        let js = "var style=document.createElement('style');style.innerHTML=\"\(css.replacingOccurrences(of: "\"", with: "\\\""))\";document.head.appendChild(style);"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKUIDelegate
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        completionHandler(alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "exit":
            NSApplication.shared.terminate(nil)

        case "verifyPassword":
            guard let password = body["password"] as? String else { return }
            handlePasswordVerification(password)

        default:
            break
        }
    }

    private func handlePasswordVerification(_ inputPassword: String) {
        guard case .lockScreen(let globals) = content else { return }
        if globals.verifyPassword(inputPassword) {
            NSLog("[Overlay] Password verified successfully")

            // Let the owner tear down secure mode (which terminates the app);
            // fall back to terminating directly if no handler is set.
            if let onUnlockSuccess {
                onUnlockSuccess()
            } else {
                NSApplication.shared.terminate(nil)
            }
        } else {
            NSLog("[Overlay] Password verification failed")
            // Notify JavaScript that password was incorrect
            webView?.evaluateJavaScript("window.onPasswordIncorrect && window.onPasswordIncorrect();", completionHandler: nil)
        }
    }
}
