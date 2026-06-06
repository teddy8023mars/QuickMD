#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>

static NSString *const QMDErrorDomain = @"com.quickmd.app";

static NSSet<NSString *> *QMDMarkdownExtensions(void) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithObjects:@"md", @"markdown", @"mdown", @"mkd", @"mdx", nil];
    });
    return extensions;
}

static BOOL QMDURLLooksLikeMarkdown(NSURL *url) {
    return [QMDMarkdownExtensions() containsObject:url.pathExtension.lowercaseString];
}

static NSError *QMDMakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:QMDErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Unknown error."}];
}

#pragma mark - Preview Window Controller

@interface QMDPreviewWindowController : NSWindowController <NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>

@property(nonatomic, copy) void (^closeHandler)(void);
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSURL *sourceFileURL;
@property(nonatomic, strong) NSURL *previewFileURL;
@property(nonatomic, strong) NSURL *lastExportedPDFURL;
@property(nonatomic, assign, getter=isPreviewReady) BOOL previewReady;
@property(nonatomic, assign) FSEventStreamRef fileWatchStream;
@property(nonatomic, assign) CGFloat pendingScrollTop;
@property(nonatomic, assign) CGFloat pendingScrollRatio;
@property(nonatomic, assign) BOOL hasPendingScrollRestore;
@property(nonatomic, assign) BOOL hasAutoResized;
@property(nonatomic, assign) BOOL pendingTOCVisible;
@property(nonatomic, copy) NSString *expectedSelfWriteContent;

- (BOOL)openMarkdownFileURL:(NSURL *)fileURL error:(NSError **)error;
- (void)reloadPreview:(id)sender;
- (void)printDocument:(id)sender;
- (void)exportPDF:(id)sender;
- (void)revealSourceFile:(id)sender;
- (BOOL)hasLoadedDocument;

@end

@implementation QMDPreviewWindowController

- (instancetype)init {
    // Initial frame will be adjusted after content loads
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenFrame = screen.visibleFrame;
    CGFloat initialWidth = MIN(900.0, screenFrame.size.width * 0.65);
    CGFloat initialHeight = MIN(700.0, screenFrame.size.height * 0.7);
    NSRect frame = NSMakeRect(0.0, 0.0, initialWidth, initialHeight);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];

    self = [super initWithWindow:window];
    if (!self) return nil;

    window.delegate = self;
    window.title = @"QuickMD";
    window.titleVisibility = NSWindowTitleVisible;
    window.tabbingMode = NSWindowTabbingModePreferred;
    window.minSize = NSMakeSize(400.0, 300.0);
    [window center];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    [configuration.userContentController addScriptMessageHandler:self name:@"checkboxToggle"];
    self.webView = [[WKWebView alloc] initWithFrame:window.contentView.bounds configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.allowsMagnification = YES;
    self.webView.allowsBackForwardNavigationGestures = NO;

    [window.contentView addSubview:self.webView];
    [window setInitialFirstResponder:self.webView];

    return self;
}

- (BOOL)hasLoadedDocument {
    return self.sourceFileURL != nil;
}

- (void)clearPendingScrollRestore {
    self.pendingScrollTop = 0.0;
    self.pendingScrollRatio = 0.0;
    self.hasPendingScrollRestore = NO;
}

- (NSURL *)rendererScriptURL {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle URLForResource:@"QuickMDRenderer" withExtension:@"sh"];
}

- (NSURL *)previewHTMLURLForFileURL:(NSURL *)fileURL error:(NSError **)error {
    NSURL *scriptURL = [self rendererScriptURL];

    if (!scriptURL) {
        if (error) {
            *error = QMDMakeError(10, @"The preview generator is missing from the app bundle.");
        }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    NSError *launchError = nil;

    task.executableURL = scriptURL;
    task.arguments = @[fileURL.path];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    if (![task launchAndReturnError:&launchError]) {
        if (error) {
            *error = launchError ?: QMDMakeError(11, @"Could not start the preview generator.");
        }
        return nil;
    }

    [task waitUntilExit];

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    NSString *stdoutString = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        NSString *message = stderrString.length > 0 ? stderrString : @"Preview generation failed.";
        if (error) {
            *error = QMDMakeError(12, [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        }
        return nil;
    }

    __block NSString *htmlPath = nil;
    [stdoutString enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            htmlPath = trimmed;
            *stop = YES;
        }
    }];

    if (htmlPath.length == 0) {
        if (error) {
            *error = QMDMakeError(13, @"Preview generation did not return an HTML path.");
        }
        return nil;
    }

    return [NSURL fileURLWithPath:htmlPath];
}

- (void)loadErrorPageWithMessage:(NSString *)message {
    NSString *safeMessage = [[message ?: @"Preview failed to load."
        stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
        stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

    NSString *html = [NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset=\"utf-8\"><style>"
         "body{margin:0;padding:40px;font:14pt/1.6 -apple-system,BlinkMacSystemFont,sans-serif;"
         "background:#1c1c1e;color:#e5e5e7;}"
         "h1{font-size:1.4em;color:#ff6961;margin:0 0 0.5em;}"
         "p{margin:0;white-space:pre-wrap;color:#a1a1a6;}"
         "@media(prefers-color-scheme:light){body{background:#fff;color:#1f2937;}"
         "h1{color:#dc2626;}p{color:#6b7280;}}"
         "</style></head><body><h1>Could not open document</h1><p>%@</p></body></html>",
        safeMessage];

    [self.webView loadHTMLString:html baseURL:nil];
    self.previewReady = NO;
}

- (BOOL)openMarkdownFileURL:(NSURL *)fileURL error:(NSError **)error {
    NSURL *standardURL = fileURL.fileURL ? fileURL.URLByStandardizingPath : [NSURL fileURLWithPath:fileURL.path];
    NSURL *previewURL = [self previewHTMLURLForFileURL:standardURL error:error];

    if (!previewURL) {
        [self loadErrorPageWithMessage:error && *error ? (*error).localizedDescription : nil];
        return NO;
    }

    BOOL fileChanged = ![standardURL isEqual:self.sourceFileURL];

    self.sourceFileURL = standardURL;
    self.previewFileURL = previewURL;
    self.previewReady = NO;
    self.lastExportedPDFURL = nil;

    self.window.title = [NSString stringWithFormat:@"QuickMD — %@", standardURL.lastPathComponent];
    self.window.representedURL = standardURL;
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:standardURL];

    [self.webView loadFileURL:previewURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];

    if (fileChanged || !self.fileWatchStream) {
        [self startWatchingSourceFile];
    }

    return YES;
}

- (void)reloadPreview:(id)sender {
    if (!self.sourceFileURL) return;

    if (!self.isPreviewReady) {
        NSError *error = nil;
        if (![self openMarkdownFileURL:self.sourceFileURL error:&error]) {
            [self presentError:error];
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSString *captureScript =
        @"(() => {"
         "  const doc = document.documentElement;"
         "  const body = document.body;"
         "  const viewportHeight = window.innerHeight || doc.clientHeight || 0;"
         "  const scrollHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0);"
         "  const maxScroll = Math.max(scrollHeight - viewportHeight, 0);"
         "  const scrollTop = Math.max(window.scrollY || window.pageYOffset || doc.scrollTop || body.scrollTop || 0, 0);"
         "  const scrollRatio = maxScroll > 0 ? scrollTop / maxScroll : 0;"
         "  const tocVisible = document.body.classList.contains('has-toc');"
         "  return { scrollTop, scrollRatio, tocVisible };"
         "})()";

    [self.webView evaluateJavaScript:captureScript completionHandler:^(id result, NSError *scriptError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf clearPendingScrollRestore];

        if (!scriptError && [result isKindOfClass:NSDictionary.class]) {
            NSDictionary *scrollState = (NSDictionary *)result;
            NSNumber *scrollTop = scrollState[@"scrollTop"];
            NSNumber *scrollRatio = scrollState[@"scrollRatio"];
            NSNumber *tocVisible = scrollState[@"tocVisible"];

            if ([scrollTop isKindOfClass:NSNumber.class]) {
                strongSelf.pendingScrollTop = scrollTop.doubleValue;
                strongSelf.hasPendingScrollRestore = YES;
            }
            if ([scrollRatio isKindOfClass:NSNumber.class]) {
                strongSelf.pendingScrollRatio = scrollRatio.doubleValue;
            }
            if ([tocVisible isKindOfClass:NSNumber.class]) {
                strongSelf.pendingTOCVisible = tocVisible.boolValue;
            }
        }

        NSError *error = nil;
        if (![strongSelf openMarkdownFileURL:strongSelf.sourceFileURL error:&error]) {
            [strongSelf clearPendingScrollRestore];
            [strongSelf presentError:error];
        }
    }];
}

- (void)printDocument:(id)sender {
    if (!self.isPreviewReady) return;
    NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
    NSPrintOperation *operation = [self.webView printOperationWithPrintInfo:printInfo];
    [operation runOperationModalForWindow:self.window delegate:nil didRunSelector:NULL contextInfo:NULL];
}

- (void)createPDFWithCompletion:(void (^)(NSData *pdfData, NSError *error))completion {
    if (!self.isPreviewReady) {
        if (completion) {
            completion(nil, QMDMakeError(20, @"Wait until the preview finishes loading before exporting."));
        }
        return;
    }
    [self.webView createPDFWithConfiguration:nil completionHandler:^(NSData *pdfData, NSError *error) {
        if (completion) completion(pdfData, error);
    }];
}

- (NSString *)defaultPDFFileName {
    NSString *sourceName = self.sourceFileURL.lastPathComponent ?: @"Document";
    NSString *stem = [sourceName stringByDeletingPathExtension];
    if (stem.length == 0) stem = sourceName;
    return [stem stringByAppendingPathExtension:@"pdf"];
}

- (void)exportPDF:(id)sender {
    if (!self.sourceFileURL) return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePDF];
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = [self defaultPDFFileName];
    panel.directoryURL = self.sourceFileURL.URLByDeletingLastPathComponent;

    if ([panel runModal] != NSModalResponseOK || panel.URL == nil) return;

    NSURL *destinationURL = panel.URL;
    __weak typeof(self) weakSelf = self;

    [self createPDFWithCompletion:^(NSData *pdfData, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || pdfData.length == 0) {
                [weakSelf presentError:error ?: QMDMakeError(21, @"Could not create the PDF export.")];
                return;
            }
            NSError *writeError = nil;
            if (![pdfData writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError]) {
                [weakSelf presentError:writeError];
                return;
            }
            weakSelf.lastExportedPDFURL = destinationURL;
        });
    }];
}

- (void)revealSourceFile:(id)sender {
    if (!self.sourceFileURL) return;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.sourceFileURL]];
}

#pragma mark - File Watching

static void QMDFSEventCallback(ConstFSEventStreamRef streamRef,
                               void *clientCallBackInfo,
                               size_t numEvents,
                               void *eventPaths,
                               const FSEventStreamEventFlags eventFlags[],
                               const FSEventStreamEventId eventIds[]) {
    QMDPreviewWindowController *controller = (__bridge QMDPreviewWindowController *)clientCallBackInfo;
    NSString *watchedName = controller.sourceFileURL.lastPathComponent;
    NSArray<NSString *> *paths = (__bridge NSArray *)eventPaths;

    for (NSUInteger i = 0; i < numEvents; i++) {
        NSString *changedName = paths[i].lastPathComponent;
        if ([changedName isEqualToString:watchedName]) {
            if (controller.expectedSelfWriteContent) {
                NSString *current = [NSString stringWithContentsOfURL:controller.sourceFileURL
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
                if (current && [current isEqualToString:controller.expectedSelfWriteContent]) {
                    controller.expectedSelfWriteContent = nil; // our own write; nothing to reload
                    return;
                }
            }
            [controller reloadPreview:nil];
            return;
        }
    }
}

- (void)startWatchingSourceFile {
    [self stopWatchingSourceFile];
    if (!self.sourceFileURL) return;

    NSString *directoryPath = self.sourceFileURL.URLByDeletingLastPathComponent.path;
    NSArray *pathsToWatch = @[directoryPath];
    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};

    FSEventStreamRef stream = FSEventStreamCreate(
        NULL, &QMDFSEventCallback, &context,
        (__bridge CFArrayRef)pathsToWatch,
        kFSEventStreamEventIdSinceNow, 0.3,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes);

    if (!stream) return;

    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
    FSEventStreamStart(stream);
    self.fileWatchStream = stream;
}

- (void)stopWatchingSourceFile {
    if (self.fileWatchStream) {
        FSEventStreamStop(self.fileWatchStream);
        FSEventStreamInvalidate(self.fileWatchStream);
        FSEventStreamRelease(self.fileWatchStream);
        self.fileWatchStream = NULL;
    }
}

#pragma mark - Window Delegate

- (void)windowWillClose:(NSNotification *)notification {
    [self stopWatchingSourceFile];
    [self clearPendingScrollRestore];
    if (self.closeHandler) self.closeHandler();
}

#pragma mark - Auto Resize

- (void)autoResizeWindowToFitContent {
    self.hasAutoResized = YES;

    NSString *script =
        @"(() => {"
         "  const body = document.body;"
         "  const doc = document.documentElement;"
         "  const contentHeight = Math.max(body.scrollHeight, body.offsetHeight, doc.scrollHeight, doc.offsetHeight);"
         "  const hasWideContent = !!(document.querySelector('table, .mermaid-diagram, pre code'));"
         "  return JSON.stringify({ contentHeight: contentHeight, hasWideContent: hasWideContent });"
         "})()";

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error || !result || ![result isKindOfClass:[NSString class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyAutoResizeWithJSON:(NSString *)result];
        });
    }];
}

- (void)applyAutoResizeWithJSON:(NSString *)json {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!info) return;

    CGFloat contentHeight = [info[@"contentHeight"] doubleValue];
    BOOL hasWideContent = [info[@"hasWideContent"] boolValue];

    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    NSRect screenFrame = screen.visibleFrame;

    // Width: wider for tables/code/diagrams, narrower for pure text
    CGFloat idealWidth = hasWideContent ? 1000.0 : 820.0;
    CGFloat maxWidth = screenFrame.size.width * 0.75;
    CGFloat finalWidth = MIN(idealWidth, maxWidth);

    // Height: fit content but cap at screen limit
    CGFloat titleBarHeight = 28.0;
    CGFloat padding = 80.0;
    CGFloat idealHeight = contentHeight + titleBarHeight + padding;
    CGFloat maxHeight = screenFrame.size.height * 0.85;
    CGFloat minHeight = 400.0;
    CGFloat finalHeight = MAX(minHeight, MIN(idealHeight, maxHeight));

    // Calculate centered position
    CGFloat x = screenFrame.origin.x + (screenFrame.size.width - finalWidth) / 2.0;
    CGFloat y = screenFrame.origin.y + (screenFrame.size.height - finalHeight) / 2.0;
    NSRect newFrame = NSMakeRect(x, y, finalWidth, finalHeight);

    [self.window setFrame:newFrame display:YES animate:YES];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"checkboxToggle"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *body = (NSDictionary *)message.body;
    // The viewer computes the exact source offset of the checkbox marker from marked's own
    // token stream, so the native side never re-parses the Markdown. We only trust an offset
    // that still points at a literal "[ ]"/"[x]" — otherwise we refuse to write.
    NSNumber *offsetNumber = body[@"offset"];
    if (![offsetNumber isKindOfClass:[NSNumber class]]) return;
    NSInteger offset = offsetNumber.integerValue;
    BOOL checked = [body[@"checked"] boolValue];

    if (!self.sourceFileURL) return;

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfURL:self.sourceFileURL
                                                encoding:NSUTF8StringEncoding
                                                   error:&readError];
    if (readError || !content) return;

    if (offset < 0 || offset + 3 > (NSInteger)content.length) return;
    NSRange boxRange = NSMakeRange((NSUInteger)offset, 3);

    // Safety check: the offset must still land on a checkbox marker. If the source drifted
    // (e.g. edited since render), this fails and we abort rather than corrupt an unrelated line.
    NSString *marker = [content substringWithRange:boxRange];
    static NSRegularExpression *markerRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markerRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\[[ xX]\\]$" options:0 error:nil];
    });
    if ([markerRegex numberOfMatchesInString:marker options:0 range:NSMakeRange(0, marker.length)] == 0) {
        return;
    }

    NSString *replacement = checked ? @"[x]" : @"[ ]";
    NSMutableString *mutableContent = [content mutableCopy];
    [mutableContent replaceCharactersInRange:boxRange withString:replacement];

    // Stale-write guard: if the file changed on disk since we rendered, reload instead of clobbering.
    NSString *latest = [NSString stringWithContentsOfURL:self.sourceFileURL
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (latest && ![latest isEqualToString:content]) {
        [self reloadPreview:nil];
        return;
    }

    // Record what we are about to write so the FSEvent callback can ignore our own change.
    self.expectedSelfWriteContent = mutableContent;

    NSError *writeError = nil;
    if (![mutableContent writeToURL:self.sourceFileURL
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&writeError]) {
        self.expectedSelfWriteContent = nil; // write failed; let future events reload normally
        return;
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.previewReady = YES;

    // Auto-resize window to fit content on first load
    if (!self.hasAutoResized) {
        [self autoResizeWindowToFitContent];
    }

    // Restore TOC sidebar state
    if (self.pendingTOCVisible) {
        NSString *tocScript = @"if (window.toggleTOC && !document.body.classList.contains('has-toc')) { window.toggleTOC(); }";
        [self.webView evaluateJavaScript:tocScript completionHandler:nil];
        self.pendingTOCVisible = NO;
    }

    if (!self.hasPendingScrollRestore) return;

    CGFloat scrollTop = self.pendingScrollTop;
    CGFloat scrollRatio = self.pendingScrollRatio;
    [self clearPendingScrollRestore];

    NSString *restoreScript = [NSString stringWithFormat:
        @"(() => {"
         "  const requestedTop = %@;"
         "  const requestedRatio = %@;"
         "  const restore = () => {"
         "    const doc = document.documentElement;"
         "    const body = document.body;"
         "    const viewportHeight = window.innerHeight || doc.clientHeight || 0;"
         "    const scrollHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0);"
         "    const maxScroll = Math.max(scrollHeight - viewportHeight, 0);"
         "    let target = Math.min(Math.max(requestedTop, 0), maxScroll);"
         "    if (requestedRatio >= 0.98 && maxScroll > 0) target = maxScroll;"
         "    window.scrollTo(0, target);"
         "  };"
         "  restore();"
         "  requestAnimationFrame(restore);"
         "  requestAnimationFrame(() => requestAnimationFrame(restore));"
         "})()",
        @(scrollTop), @(scrollRatio)];

    [self.webView evaluateJavaScript:restoreScript completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.previewReady = NO;
    [self loadErrorPageWithMessage:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.previewReady = NO;
    [self loadErrorPageWithMessage:error.localizedDescription];
}

- (void)openLinkedURL:(NSURL *)url {
    if (!url) return;
    if (url.isFileURL && QMDURLLooksLikeMarkdown(url)) {
        NSError *error = nil;
        if (![self openMarkdownFileURL:url error:&error]) [self presentError:error];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated && url) {
        [self openLinkedURL:url];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (nullable WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
              forNavigationAction:(WKNavigationAction *)navigationAction
                   windowFeatures:(WKWindowFeatures *)windowFeatures {
    [self openLinkedURL:navigationAction.request.URL];
    return nil;
}

@end

#pragma mark - App Delegate

@interface QMDAppDelegate : NSObject <NSApplicationDelegate, NSUserInterfaceValidations>

@property(nonatomic, strong) NSMutableSet<QMDPreviewWindowController *> *windowControllers;
@property(nonatomic, assign) BOOL openedFileDuringLaunch;

@end

@implementation QMDAppDelegate

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _windowControllers = [NSMutableSet set];
    return self;
}

- (void)installMainMenu {
    NSString *appName = @"QuickMD";
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:appName];

    // App Menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"About %@", appName]
                                                       action:@selector(orderFrontStandardAboutPanel:)
                                                keyEquivalent:@""];
    aboutItem.target = NSApp;
    [appMenu addItem:aboutItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hideItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                                                      action:@selector(hide:) keyEquivalent:@"h"];
    hideItem.target = NSApp;
    [appMenu addItem:hideItem];

    NSMenuItem *hideOthersItem = [[NSMenuItem alloc] initWithTitle:@"Hide Others"
                                                            action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthersItem.keyEquivalentModifierMask = (NSEventModifierFlagOption | NSEventModifierFlagCommand);
    hideOthersItem.target = NSApp;
    [appMenu addItem:hideOthersItem];

    NSMenuItem *showAllItem = [[NSMenuItem alloc] initWithTitle:@"Show All"
                                                         action:@selector(unhideAllApplications:) keyEquivalent:@""];
    showAllItem.target = NSApp;
    [appMenu addItem:showAllItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                                      action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [appMenu addItem:quitItem];
    appMenuItem.submenu = appMenu;

    // File Menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileMenuItem];

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItem:[self menuItemWithTitle:@"Open..." action:@selector(openDocument:)
                                 keyEquivalent:@"o" modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[self menuItemWithTitle:@"Reload" action:@selector(reloadPreview:)
                                 keyEquivalent:@"r" modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItem:[self menuItemWithTitle:@"Print..." action:@selector(printDocument:)
                                 keyEquivalent:@"p" modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[self menuItemWithTitle:@"Export as PDF..." action:@selector(exportPDF:)
                                 keyEquivalent:@"e" modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    [fileMenu addItem:[self menuItemWithTitle:@"Reveal Source File" action:@selector(revealSourceFile:)
                                 keyEquivalent:@"" modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    closeItem.target = nil;
    [fileMenu addItem:closeItem];
    fileMenuItem.submenu = fileMenu;

    // Edit Menu
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:editMenuItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItem:[self stdMenuItemWithTitle:@"Copy" action:@selector(copy:)
                                    keyEquivalent:@"c" modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self stdMenuItemWithTitle:@"Select All" action:@selector(selectAll:)
                                    keyEquivalent:@"a" modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self menuItemWithTitle:@"Find..." action:@selector(openFindPanel:)
                                 keyEquivalent:@"f" modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItemWithTitle:@"Find Next" action:@selector(findNextMatch:)
                                 keyEquivalent:@"g" modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItemWithTitle:@"Find Previous" action:@selector(findPreviousMatch:)
                                 keyEquivalent:@"G" modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    editMenuItem.submenu = editMenu;

    // View Menu
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewMenuItem];

    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItem:[self menuItemWithTitle:@"Toggle Dark Mode" action:@selector(toggleDarkMode:)
                                 keyEquivalent:@"d" modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    [viewMenu addItem:[self menuItemWithTitle:@"Toggle TOC Sidebar" action:@selector(toggleTOC:)
                                 keyEquivalent:@"t" modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    viewMenuItem.submenu = viewMenu;

    [NSApp setMainMenu:mainMenu];
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title action:(SEL)action
                     keyEquivalent:(NSString *)keyEquivalent modifierMask:(NSEventModifierFlags)modifierMask {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
    item.target = self;
    item.keyEquivalentModifierMask = modifierMask;
    return item;
}

- (NSMenuItem *)stdMenuItemWithTitle:(NSString *)title action:(SEL)action
                        keyEquivalent:(NSString *)keyEquivalent modifierMask:(NSEventModifierFlags)modifierMask {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
    item.target = nil;
    item.keyEquivalentModifierMask = modifierMask;
    return item;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (!self.openedFileDuringLaunch) {
        [self openDocument:nil];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag && self.windowControllers.count == 0) {
        [self openDocument:nil];
        return NO;
    }
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    self.openedFileDuringLaunch = YES;
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:filenames.count];
    for (NSString *filename in filenames) {
        [urls addObject:[NSURL fileURLWithPath:filename]];
    }
    [self openFileURLs:urls reuseCurrentWindow:NO];
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (QMDPreviewWindowController *)currentPreviewWindowController {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if ([window.windowController isKindOfClass:QMDPreviewWindowController.class]) {
        return (QMDPreviewWindowController *)window.windowController;
    }
    return nil;
}

- (QMDPreviewWindowController *)windowControllerForFileURL:(NSURL *)fileURL {
    NSURL *standardURL = fileURL.fileURL ? fileURL.URLByStandardizingPath : [NSURL fileURLWithPath:fileURL.path];
    for (QMDPreviewWindowController *controller in self.windowControllers) {
        if ([controller.sourceFileURL isEqual:standardURL]) return controller;
    }
    return nil;
}

- (QMDPreviewWindowController *)newWindowController {
    QMDPreviewWindowController *controller = [[QMDPreviewWindowController alloc] init];
    __weak typeof(self) weakSelf = self;
    __weak QMDPreviewWindowController *weakController = controller;
    controller.closeHandler = ^{
        if (weakController) [weakSelf.windowControllers removeObject:weakController];
    };
    [self.windowControllers addObject:controller];
    return controller;
}

- (void)openFileURLs:(NSArray<NSURL *> *)urls reuseCurrentWindow:(BOOL)reuseCurrentWindow {
    QMDPreviewWindowController *reusableController = reuseCurrentWindow ? [self currentPreviewWindowController] : nil;

    for (NSUInteger index = 0; index < urls.count; index += 1) {
        NSURL *fileURL = urls[index];
        QMDPreviewWindowController *existingController = [self windowControllerForFileURL:fileURL];
        if (existingController) {
            [existingController showWindow:self];
            [existingController.window makeKeyAndOrderFront:self];
            [NSApp activateIgnoringOtherApps:YES];
            continue;
        }

        QMDPreviewWindowController *controller = (index == 0 && reusableController) ? reusableController : [self newWindowController];
        NSError *error = nil;

        if (![controller openMarkdownFileURL:fileURL error:&error]) {
            if (controller != reusableController) {
                [self.windowControllers removeObject:controller];
                [controller close];
            }
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert runModal];
            continue;
        }

        [controller showWindow:self];
        [controller.window makeKeyAndOrderFront:self];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (void)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"md"],
        [UTType typeWithFilenameExtension:@"markdown"],
        [UTType typeWithFilenameExtension:@"mdown"],
        [UTType typeWithFilenameExtension:@"mkd"],
        [UTType typeWithFilenameExtension:@"mdx"],
    ];
    panel.prompt = @"Open";
    [NSApp activateIgnoringOtherApps:YES];

    if ([panel runModal] != NSModalResponseOK) return;
    [self openFileURLs:panel.URLs reuseCurrentWindow:NO];
}

- (void)reloadPreview:(id)sender { [[self currentPreviewWindowController] reloadPreview:sender]; }
- (void)printDocument:(id)sender { [[self currentPreviewWindowController] printDocument:sender]; }
- (void)exportPDF:(id)sender { [[self currentPreviewWindowController] exportPDF:sender]; }
- (void)revealSourceFile:(id)sender { [[self currentPreviewWindowController] revealSourceFile:sender]; }

- (void)toggleDarkMode:(id)sender {
    QMDPreviewWindowController *controller = [self currentPreviewWindowController];
    if (controller && controller.isPreviewReady) {
        [controller.webView evaluateJavaScript:@"toggleTheme()" completionHandler:nil];
    }
}

- (void)toggleTOC:(id)sender {
    QMDPreviewWindowController *controller = [self currentPreviewWindowController];
    if (controller && controller.isPreviewReady) {
        [controller.webView evaluateJavaScript:@"toggleTOC()" completionHandler:nil];
    }
}

- (void)openFindPanel:(id)sender {
    [self runJS:@"if(typeof qmdToggleFindBar==='function')qmdToggleFindBar();"];
}
- (void)findNextMatch:(id)sender {
    [self runJS:@"if(typeof qmdFindNextMatch==='function')qmdFindNextMatch();"];
}
- (void)findPreviousMatch:(id)sender {
    [self runJS:@"if(typeof qmdFindPreviousMatch==='function')qmdFindPreviousMatch();"];
}

- (void)runJS:(NSString *)script {
    QMDPreviewWindowController *controller = [self currentPreviewWindowController];
    if (!controller || !controller.isPreviewReady) return;
    [controller.webView evaluateJavaScript:script completionHandler:nil];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;
    if (action == @selector(openDocument:)) return YES;

    QMDPreviewWindowController *controller = [self currentPreviewWindowController];
    if (!controller || !controller.hasLoadedDocument) return NO;

    if (action == @selector(reloadPreview:) || action == @selector(revealSourceFile:)) return YES;
    if (action == @selector(toggleDarkMode:) || action == @selector(toggleTOC:) ||
        action == @selector(openFindPanel:) || action == @selector(findNextMatch:) ||
        action == @selector(findPreviousMatch:) || action == @selector(printDocument:) ||
        action == @selector(exportPDF:)) {
        return controller.isPreviewReady;
    }
    return YES;
}

@end

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        QMDAppDelegate *delegate = [[QMDAppDelegate alloc] init];
        application.delegate = delegate;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        [delegate installMainMenu];
        [application run];
    }
    return EXIT_SUCCESS;
}
