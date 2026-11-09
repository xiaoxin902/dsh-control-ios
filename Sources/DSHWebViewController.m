// SPDX-License-Identifier: MIT
#import "DSHWebViewController.h"

#import <WebKit/WebKit.h>

#import "DSHService.h"

/// APIs dsh's front end calls that WebKit only gained in iOS 17.4 (and
/// Promise.withResolvers in 17.4, AbortSignal.timeout in 16.4). On an older
/// system they are undefined and the page throws before it can start, so a
/// minimal implementation goes in before any page script runs.
static NSString *const DSHShimSource =
    @"(function() {"
     "  /* The probe script has its own; this one is for the shim, whose reports"
     "     (quiet.arm above all) otherwise throw on an undefined send(). */"
     "  const send = (kind, parts) => {"
     "    try {"
     "      const text = (parts || []).map((part) => {"
     "        try { return typeof part === 'object' ? JSON.stringify(part).slice(0, 300) : String(part); }"
     "        catch (error) { return ''; }"
     "      }).join(' ');"
     "      window.webkit.messageHandlers.dsh.postMessage(kind + ' ' + text.slice(0, 600));"
     "    } catch (error) {}"
     "  };"
     "  try {"
     "    if (typeof AbortSignal !== 'undefined' && !AbortSignal.any) {"
     "      AbortSignal.any = function(signals) {"
     "        var controller = new AbortController();"
     "        var list = Array.prototype.slice.call(signals);"
     "        for (var i = 0; i < list.length; i++) {"
     "          if (list[i].aborted) { controller.abort(list[i].reason); return controller.signal; }"
     "        }"
     "        list.forEach(function(signal) {"
     "          signal.addEventListener('abort', function() { controller.abort(signal.reason); }, { once: true });"
     "        });"
     "        return controller.signal;"
     "      };"
     "    }"
     "    if (typeof AbortSignal !== 'undefined' && !AbortSignal.timeout) {"
     "      AbortSignal.timeout = function(ms) {"
     "        var controller = new AbortController();"
     "        setTimeout(function() {"
     "          var reason = new Error('TimeoutError');"
     "          reason.name = 'TimeoutError';"
     "          controller.abort(reason);"
     "        }, ms);"
     "        return controller.signal;"
     "      };"
     "    }"
     "    if (typeof Promise !== 'undefined' && !Promise.withResolvers) {"
     "      Promise.withResolvers = function() {"
     "        var resolve, reject;"
     "        var promise = new Promise(function(res, rej) { resolve = res; reject = rej; });"
     "        return { promise: promise, resolve: resolve, reject: reject };"
     "      };"
     "    }"
     "    if (typeof Object.groupBy !== 'function') {"
     "      Object.groupBy = function(items, callback) {"
     "        var result = Object.create(null);"
     "        var index = 0;"
     "        for (var item of items) {"
     "          var key = callback(item, index++);"
     "          (result[key] = result[key] || []).push(item);"
     "        }"
     "        return result;"
     "      };"
     "    }"
     "  } catch (error) {"
     "    console.error('DSH shim failed', error);"
     "  }"
     "})();";

@interface DSHWebViewController () <WKNavigationDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) NSTimeInterval quietUntil;
@property (nonatomic, strong) NSTimer *overlayTimer;
@end

/// Forwards what the page logs, and every fetch it makes, into the app's log.
@interface DSHPageBridge : NSObject <WKScriptMessageHandler>
@end

@implementation DSHPageBridge

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSString *text = [message.body isKindOfClass:NSString.class] ? message.body : [message.body description];
    if ([text hasPrefix:@"quiet.arm"]) {
        DSHLog(@"page: quiet.arm (stop tapped)");
        [NSNotificationCenter.defaultCenter postNotificationName:@"DSHPageQuietArmedNotification" object:nil];
        return;
    }
    DSHLog(@"page: %@", text);
}

@end

/// Runs before any page script: reports console errors, uncaught errors and
/// each fetch (method, URL, status) to the app, which writes them to
/// /tmp/dsh-control.log.
static NSString *const DSHPageProbeSource =
    @"(function() {"
     "  const send = (kind, parts) => {"
     "    try {"
     "      const text = parts.map((part) => {"
     "        try { return typeof part === 'object' ? JSON.stringify(part).slice(0, 300) : String(part); }"
     "        catch (error) { return String(part); }"
     "      }).join(' ');"
     "      window.webkit.messageHandlers.dsh.postMessage(kind + ' ' + text.slice(0, 600));"
     "    } catch (error) {}"
     "  };"
     "  const consoleError = console.error;"
     "  console.error = function() { send('console.error', Array.prototype.slice.call(arguments)); consoleError.apply(console, arguments); };"
     "  const consoleWarn = console.warn;"
     "  console.warn = function() { send('console.warn', Array.prototype.slice.call(arguments)); consoleWarn.apply(console, arguments); };"
     "  window.addEventListener('error', (event) => send('window.error', [event.message, (event.filename || '') + ':' + event.lineno]));"
     "  window.addEventListener('unhandledrejection', (event) => {"
     "    const reason = event.reason;"
     "    send('unhandledrejection', [String(reason && (reason.stack || reason.message || reason))]);"
     "  });"
     "  const originalFetch = window.fetch;"
     "  window.fetch = function(input, init) {"
     "    const url = typeof input === 'string' ? input : (input && input.url) || '';"
     "    const method = (init && init.method) || (input && input.method) || 'GET';"
     "    const started = Date.now();"
     "    const isApi = url.indexOf('api/') >= 0;"
     "    if (isApi && init && typeof init.body === 'string') send('api.request', [method, url, init.body.slice(0, 200)]);"
     "    return originalFetch.apply(this, arguments).then((response) => {"
     "      send('fetch', [method, url, response.status, (Date.now() - started) + 'ms']);"
     "      const type = response.headers.get('content-type') || '';"
     "      if (isApi && type.indexOf('json') >= 0) {"
     "        response.clone().text().then((text) => send('api.response', [method, url, response.status, text.slice(0, 300)])).catch(() => {});"
     "      }"
     "      return response;"
     "    }, (error) => {"
     "      send('fetch.error', [method, url, String((error && error.message) || error), (Date.now() - started) + 'ms']);"
     "      throw error;"
     "    });"
     "  };"
     "  if (window.WebSocket) {"
     "    const OriginalWebSocket = window.WebSocket;"
     "    window.WebSocket = new Proxy(OriginalWebSocket, {"
     "      construct(target, args) {"
     "        const socket = new target(...args);"
     "        send('ws.create', [String(args[0])]);"
     "        socket.addEventListener('open', () => send('ws.open', [String(args[0])]));"
     "        socket.addEventListener('close', (event) => send('ws.close', [String(args[0]), event.code, event.reason]));"
     "        socket.addEventListener('error', () => send('ws.error', [String(args[0])]));"
     "        return socket;"
     "      }"
     "    });"
     "  }"
     "  if (window.EventSource) {"
     "    const OriginalEventSource = window.EventSource;"
     "    window.EventSource = new Proxy(OriginalEventSource, {"
     "      construct(target, args) {"
     "        const source = new target(...args);"
     "        send('es.create', [String(args[0])]);"
     "        source.addEventListener('error', () => send('es.error', [String(args[0]), source.readyState]));"
     "        return source;"
     "      }"
     "    });"
     "  }"
     // 停止后 dsh 会把焦点塞回输入框、iOS 就弹键盘。取消请求一发出就进入 3 秒
     // 抑制窗口：这期间没有用户手势指向的 focus 调用直接吞掉；自己点输入框放行。
     "  let quietUntil = 0;"
     "  let gestureTarget = null;"
     "  let gestureAt = 0;"
     "  const isControl = (element) => {"
     "    try { return !!(element && element.closest && element.closest('button,[role=\"button\"],[role=\"menuitem\"],[role=\"tab\"],a')); }"
     "    catch (error) { return false; }"
     "  };"
     "  const markGesture = (event) => {"
     "    gestureTarget = event.target;"
     "    gestureAt = Date.now();"
     // 点按钮（+、···、回退、停止）后页面常顺手聚焦输入框；给一个 1.2 秒的短窗口
     "    if (isControl(event.target)) quietUntil = Math.max(quietUntil, Date.now() + 1200);"
     "  };"
     "  ['pointerdown', 'touchstart', 'mousedown', 'keyup'].forEach((type) => {"
     "    document.addEventListener(type, markGesture, true);"
     "  });"
     "  const quiet = () => Date.now() < quietUntil;"
     "  const intended = (element) => {"
     "    if (!gestureTarget || !element || Date.now() - gestureAt > 1500) return false;"
     "    if (isControl(gestureTarget) && !isControl(element)) return false;"
     "    if (gestureTarget === element) return true;"
     "    try { return typeof gestureTarget.contains === 'function' && gestureTarget.contains(element); } catch (error) { return false; }"
     "  };"
     "  const nativeFocus = HTMLElement.prototype.focus;"
     "  HTMLElement.prototype.focus = function (options) {"
     "    if (quiet() && !intended(this)) {"
     "      send('focus.blocked', [(this.tagName || '').toLowerCase(), String(this.className || '').slice(0, 60)]);"
     "      return;"
     "    }"
     "    return nativeFocus.call(this, options);"
     "  };"
     "  document.addEventListener('focusin', (event) => {"
     "    if (!quiet() || intended(event.target)) return;"
     "    const target = event.target;"
     "    send('focus.reverted', [(target.tagName || '').toLowerCase(), String(target.className || '').slice(0, 60)]);"
     "    try { if (target && typeof target.blur === 'function') target.blur(); } catch (error) {}"
     "  }, true);"
     "  let quietRequests = 0;"
     "  const armQuiet = () => { quietUntil = Date.now() + 3000; quietRequests += 1; send('quiet.arm', []); };"
     "  const originalFetchForCancel = window.fetch;"
     "  window.fetch = function (input, init) {"
     "    const url = typeof input === 'string' ? input : (input && input.url) || '';"
     "    const isCancel = url.indexOf('session/cancel') >= 0;"
     "    if (isCancel) armQuiet();"
     "    const result = originalFetchForCancel.apply(this, arguments);"
     "    if (isCancel && result && typeof result.then === 'function') result.then(armQuiet, () => {});"
     "    return result;"
     "  };"
     "  window.addEventListener('dsh:quiet-stats', () => send('quiet', [quietRequests, Date.now() < quietUntil]));"
     "  window.addEventListener('dsh:probe-overlays', () => {"
     "    const found = [];"
     "    for (const node of document.querySelectorAll('body *')) {"
     "      let style = null;"
     "      try { style = getComputedStyle(node); } catch (error) { continue; }"
     "      if (!style) continue;"
     "      const filter = style.backdropFilter || style.webkitBackdropFilter;"
     "      const background = style.backgroundColor || '';"
     "      const alpha = background.indexOf('rgba(') === 0 && background.indexOf(', 1)') < 0;"
     "      const positioned = style.position === 'fixed' || style.position === 'absolute';"
     "      const floating = filter && filter !== 'none' ? true : (alpha && positioned);"
     "      if (!floating) continue;"
     "      const classes = node.className && node.className.toString ? node.className.toString().slice(0, 140) : '';"
     "      found.push((node.tagName || '').toLowerCase() + '|' + classes + '|bg=' + style.backgroundColor + '|bf=' + filter);"
     "      if (found.length >= 6) break;"
     "    }"
     "    send('overlays', [found.join('  \\n  ').slice(0, 900)]);"
     "  });"
     "  /* Reads back what the page really resolved, so a theme edit can be checked"
     "     from the app log instead of guessed at. No CSS is injected here. */"
     "  setTimeout(() => {"
     "    try {"
     "      const cs = getComputedStyle(document.documentElement);"
     "      const bs = getComputedStyle(document.body);"
     "      send('theme.check', [cs.getPropertyValue('--dsw-menu-surface-fill').trim(), cs.getPropertyValue('--dsw-menu-backdrop-filter').trim(), bs.getPropertyValue('--dsw-menu-surface-fill').trim(), String(document.styleSheets.length)]);"
     "      const hits = [];"
     "      for (const sheet of document.styleSheets) {"
     "        let rules = null;"
     "        try { rules = sheet.cssRules; } catch (error) { continue; }"
     "        for (const rule of rules || []) {"
     "          const text = rule.cssText || '';"
     "          if (text.indexOf('--dsw-menu-surface-fill') < 0) continue;"
     "          const value = (text.match(/--dsw-menu-surface-fill:\\s*[^;}]*/) || [''])[0];"
     "          hits.push((rule.selectorText || '@').slice(0, 70) + ' => ' + value);"
     "          if (hits.length >= 5) break;"
     "        }"
     "        if (hits.length >= 5) break;"
     "      }"
     "      send('theme.sheet', [hits.join('  ||  ').slice(0, 700) || 'rule not found']);"
     "    } catch (error) { send('theme.check.failed', [String(error)]); }"
     "  }, 2500);"
     "  /* Lists real popovers by geometry/role, since opaque surfaces no longer"
     "     look like overlays to the probe above. */"
     "  setTimeout(() => {"
     "    try {"
     "      const btn = document.querySelector('[class*=\"nL4_yW_moreButton\"]');"
     "      const rows = [];"
     "      let node = btn;"
     "      for (let i = 0; node && i < 9; i++, node = node.parentElement) {"
     "        const st = getComputedStyle(node);"
     "        const cls = node.className && node.className.toString ? node.className.toString() : node.tagName;"
     "        rows.push(cls.slice(0, 50) + '|pos=' + st.position + '|z=' + st.zIndex + '|ov=' + st.overflow + '|iso=' + st.isolation + '|tf=' + (st.transform === 'none' ? '-' : 'y'));"
     "      }"
     "      send('header.chain', [rows.join('  ||  ').slice(0, 900)]);"
     "    } catch (error) { send('header.chain.failed', [String(error)]); }"
     "  }, 3000);"
     "  window.addEventListener('dsh:probe-popovers', () => {"
     "    const rows = [];"
     "    for (const node of document.querySelectorAll('body *')) {"
     "      let st = null;"
     "      try { st = getComputedStyle(node); } catch (error) { continue; }"
     "      const role = node.getAttribute && node.getAttribute('role');"
     "      const fixed = st.position === 'fixed' || st.position === 'absolute';"
     "      const z = parseInt(st.zIndex, 10) || 0;"
     "      if (!(fixed && (z >= 50 || role)) && !role) continue;"
     "      if (node.offsetWidth < 40 || node.offsetHeight < 20) continue;"
     "      const cls = node.className && node.className.toString ? node.className.toString().slice(0, 90) : '';"
     "      let clippedBy = '-';"
     "      for (let p = node.parentElement; p && p !== document.body; p = p.parentElement) {"
     "        const ps = getComputedStyle(p);"
     "        if (ps.overflow !== 'visible' || ps.overflowY !== 'visible') {"
     "          clippedBy = ((p.className && p.className.toString()) || p.tagName).slice(0, 40) + ':' + ps.overflowY;"
     "          break;"
     "        }"
     "      }"
     "      rows.push((node.tagName || '').toLowerCase() + '|' + role + '|z=' + z"
     "        + '|bg=' + st.backgroundColor + '|bf=' + (st.backdropFilter || 'none')"
     "        + '|clip=' + clippedBy + '|' + cls);"
     "      if (rows.length >= 8) break;"
     "    }"
     "    send('popovers', [rows.join('  \\n  ').slice(0, 900)]);"
     "  });"
     "})();";

@implementation DSHWebViewController

- (instancetype)initWithURL:(NSURL *)url {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _url = url;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.allowsInlineMediaPlayback = YES;
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    WKUserScript *shim = [[WKUserScript alloc] initWithSource:DSHShimSource
                                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                            forMainFrameOnly:NO];
    [configuration.userContentController addUserScript:shim];
    WKUserScript *probe = [[WKUserScript alloc] initWithSource:DSHPageProbeSource
                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                forMainFrameOnly:YES];
    [configuration.userContentController addUserScript:probe];
    [configuration.userContentController addScriptMessageHandler:[DSHPageBridge new] name:@"dsh"];

    WKWebView *webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    webView.navigationDelegate = self;
    webView.allowsBackForwardNavigationGestures = YES;
    if (@available(iOS 16.4, *)) {
        webView.inspectable = NO;
    }
    [self.view addSubview:webView];
    self.webView = webView;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.hidesWhenStopped = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:spinner];
    self.spinner = spinner;

    // A bar of its own above the page: the dsh UI has controls of its own in
    // the top corners (a sidebar button, the stop button), and a button
    // floating over them made those unreachable.
    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UILabel *barTitle = [UILabel new];
    barTitle.text = self.url.host.length > 0 ? self.url.host : @"DSH";
    barTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    barTitle.textColor = UIColor.secondaryLabelColor;
    barTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.contentView addSubview:barTitle];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [closeButton addTarget:self action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    closeButton.accessibilityLabel = @"关闭";
    [bar.contentView addSubview:closeButton];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [bar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:safeArea.topAnchor constant:44],

        [barTitle.centerXAnchor constraintEqualToAnchor:bar.contentView.centerXAnchor],
        [barTitle.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],

        [closeButton.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
        [closeButton.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-12],
        [closeButton.heightAnchor constraintEqualToConstant:44],
        [closeButton.widthAnchor constraintGreaterThanOrEqualToConstant:64],

        [webView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [spinner startAnimating];
    DSHLog(@"web: loading %@", self.url.absoluteString);
    [webView loadRequest:[NSURLRequest requestWithURL:self.url]];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(quietArmed:)
                                              name:@"DSHPageQuietArmedNotification"
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(keyboardWillShow:)
                                              name:UIKeyboardWillShowNotification
                                            object:nil];
    if ([NSFileManager.defaultManager fileExistsAtPath:@"/tmp/dsh-overlay-probe.on"]) {
        __weak typeof(self) weakSelf = self;
        self.overlayTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *__unused timer) {
            [weakSelf.webView evaluateJavaScript:@"window.dispatchEvent(new Event('dsh:probe-overlays'));window.dispatchEvent(new Event('dsh:probe-popovers'))" completionHandler:nil];
        }];
    }
}

/// The page is about to put focus back in its composer after a stop; keep the
/// keyboard down for a moment unless the user taps the composer themselves.
- (void)quietArmed:(NSNotification *)notification {
    self.quietUntil = NSDate.date.timeIntervalSince1970 + 3.0;
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (NSDate.date.timeIntervalSince1970 > self.quietUntil) {
        return;
    }
    DSHLog(@"web: keyboard dismissed inside the stop window");
    [self.webView endEditing:YES];
}

- (void)dealloc {
    [self.overlayTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)closeTapped:(UIButton *)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    DSHLog(@"web: started %@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    DSHLog(@"web: committed %@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    DSHLog(@"web: finished %@ title=%@", webView.URL.absoluteString, webView.title);
    // Ask the page whether the shim is in place, so a broken shim is visible
    // in the log instead of only in the page.
    [webView evaluateJavaScript:@"typeof AbortSignal.any + ':' + typeof Promise.withResolvers"
              completionHandler:^(id result, NSError *error) {
        DSHLog(@"web: shim check %@ %@", result, error.localizedDescription ?: @"");
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    // A cancelled load is what a redirect shows; only report real trouble.
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return;
    }
    DSHLog(@"web: failed %@", error.localizedDescription);
    [self reportFailure:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    [self reportFailure:error];
}

- (void)reportFailure:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打开失败"
                                                                  message:error.localizedDescription
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction *__unused action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
