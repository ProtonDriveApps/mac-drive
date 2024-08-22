// Copyright (c) 2023 Proton AG
//
// This file is part of Proton Drive.
//
// Proton Drive is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Drive is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Drive. If not, see https://www.gnu.org/licenses/.

import WebKit
import ProtonCoreUIFoundations

final class ReleaseNotesView: WKWebView {
    
    private var appearanceObserver: NSKeyValueObservation?
    private var navigation: WKNavigation?
    private let viewModel: ReleaseNotesViewModelProtocol
    let minimalSize = CGSize(width: 250, height: 200)
    let idealSize = CGSize(width: 480, height: 414)
    
    init(viewModel: ReleaseNotesViewModelProtocol) {
        self.viewModel = viewModel
        
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = false
        
        let websitePreferences = WKWebpagePreferences()
        websitePreferences.allowsContentJavaScript = false
        websitePreferences.preferredContentMode = .desktop
        
        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        configuration.defaultWebpagePreferences = websitePreferences
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.limitsNavigationsToAppBoundDomains = true
        configuration.websiteDataStore = .nonPersistent()
        
        super.init(frame: CGRect(origin: .zero, size: idealSize), configuration: configuration)
        
        setupWebView()
        setupObservers()
        loadWebContent()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWebView() {
        uiDelegate = self
        navigationDelegate = self
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        allowsMagnification = true
        isHidden = true
        underPageBackgroundColor = ColorProvider.BackgroundNorm
    }
    
    private func setupObservers() {
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.loadWebContent()
        }
    }
    
    private func loadWebContent() {
        navigation = loadHTMLString(viewModel.releaseNotes, baseURL: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension ReleaseNotesView: WKUIDelegate {}

extension ReleaseNotesView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .other,
              navigationAction.request.mainDocumentURL?.absoluteString == "about:blank" else {
            return .cancel
        }
        return .allow
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation == self.navigation else { return }
        self.navigation = nil
        // animator is used to prevent the white about:blank page background from flashing on load
        animator().isHidden = false
    }
}
