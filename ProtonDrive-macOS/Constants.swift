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

import Foundation
import PDClient
import PDCore
import ProtonCoreEnvironment

enum Constants {
    static let reportBugURL = URL(string: "https://proton.me/support/contact")!
    
    /// Conforms to https://semver.org/#backusnaur-form-grammar-for-valid-semver-versions
    /// Configuration            App                                                         FileProvider
    ///
    /// Debug                  |    macos-drive@1.3.2-dev               |    macos-drive-fileprovider@1.3.2-dev
    /// Release-QA         |    macos-drive@1.3.2-dev+4379    |    macos-drive-fileprovider@1.3.2-dev+4379
    /// Release-External |    macos-drive@1.3.2-beta+4379  |    macos-drive-fileprovider@1.3.2-beta+4379
    /// Release-Store      |    macos-drive@1.3.2+4379             |    macos-drive-fileprovider@1.3.2+4379
    ///
    internal static let clientVersion: String = {
        guard let info = Bundle.main.infoDictionary else {
            return "macos-drive@0.0.0"
        }
        var appVersion = "macos-drive"
        if PDCore.Constants.runningInExtension {
            appVersion += "-fileprovider"
        }

        // MAJOR.MINOR.PATCH, all digits
        let version = (info["CFBundleShortVersionString"] as! String)
        appVersion += "@" + version

        // dev, alpha, beta, etc
        let identifier = (info["APP_VERSION_IDENTIFIER"] as! String)
        if !identifier.isEmpty {
            appVersion += "-\(identifier)"
        }

        // Debug or NUMBER.CONFIG, all digits
        let build = info["CFBundleVersion"] as! String
        if build.lowercased() != "debug" {
            let buildWithoutSuffix = build.components(separatedBy: ".").first ?? ""
            appVersion += "+\(buildWithoutSuffix)"
        }

        return appVersion
    }()

    internal static let versionDigits: String = {
        // the part of client version before "@"
        clientVersion.split(separator: "@").last.map(String.init) ?? "-"
    }()

    private static func loadSettingValue(for key: SettingsBundleKeys) -> String {
        // values should be placed in shared UserDefaults so appex will be able to read them
        let sharedUserDefaults = UserDefaults(suiteName: "group.ch.protonmail.protondrive")
        if let modifiedValue = sharedUserDefaults?.value(forKey: key.rawValue) as? String, !modifiedValue.isEmpty {
            return modifiedValue
        } else if let defaultValue = Bundle.main.infoDictionary?[key.rawValue] as? String {
            sharedUserDefaults?.setValue(defaultValue, forKey: key.rawValue)
            return defaultValue
        } else {
            assert(false, "No value was defined for \(key.rawValue)")
            return ""
        }
    }
    
    // MARK: - Environments
    enum SettingsBundleKeys: String {
        case host = "DEFAULT_API_HOST"
        case shareLinkHost = "SHARE_LINK_API_HOST"
    }

    static let appGroup: SettingsStorageSuite = .group(named: "group.ch.protonmail.protondrive")

    static func loadConfiguration() {
        if let dynamicDomain = dynamicDomain {
            #if LOAD_TESTING
            Constants.appGroup.userDefaults.set(dynamicDomain, forKey: Constants.SettingsBundleKeys.host.rawValue)
            print("USING DYNAMIC_DOMAIN \(dynamicDomain)")
            let environment: Environment
            if dynamicDomain.hasPrefix("http://") {
                environment = Environment.customHttp(dynamicDomain.replacingOccurrences(of: "http://", with: ""))
            } else {
                environment = Environment.custom(dynamicDomain.replacingOccurrences(of: "https://", with: ""))
            }
            #else
            let environment = Environment.custom(dynamicDomain)
            #endif
            self.userApiConfig = Configuration(environment: environment, clientVersion: clientVersion)
            #if LOAD_TESTING
            print("HOST RESOLVED TO \(self.userApiConfig.apiOrigin)")
            print("HOST RESOLVED TO \(self.userApiConfig.baseOrigin)")
            #endif
        } else {
            loadFromSettingsBundle()
            #if LOAD_TESTING
            let host = loadSettingValue(for: .host)
            print("NOT USING DYNAMIC_DOMAIN!!! TALKS TO \(host)")
            #endif
        }
    }

    static var isInUITests: Bool {
        CommandLine.arguments.contains("--uitests")
    }
    
    static var isInIntegrationTests: Bool {
        CommandLine.arguments.contains("--integrationTests")
    }
    
    static var isInUnitTests: Bool {
        CommandLine.arguments.contains("--unitTests")
    }
    
    static var isInStressTests: Bool {
        CommandLine.arguments.contains("--stressTests")
    }
    
    static var isInAnyTests: Bool {
        isInUITests || isInIntegrationTests || isInUnitTests || isInStressTests
    }

    static let activeFrequency: TimeInterval = 6 * 60 * 60 // 6 hours

    private static func loadFromSettingsBundle() {
        var environment = Environment.driveProd
        
        #if HAS_QA_FEATURES || LOAD_TESTING
        let host = loadSettingValue(for: .host)
        switch host {
        case "proton.black", "drive.proton.black":
            environment = .black
        case "payments.proton.black":
            environment = .blackPayment
        case let scientist where scientist.hasSuffix(".black"): // scientists only
            environment = .custom(scientist)
        case let scientist where scientist.hasSuffix(".black/"): // scientists with trailing /, used by QA in some cases
            environment = .custom(String(scientist.dropLast()))
        case let ip where ip.range(of: "^(http:\\/\\/|https:\\/\\/)?\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}(:\\d+)?$",
                                   options: [.regularExpression]) != nil:
            if ip.hasPrefix("http://") {
                environment = .customHttp(ip.replacingOccurrences(of: "http://", with: ""))
            } else {
                environment = .custom(ip.replacingOccurrences(of: "https://", with: ""))
            }
        case let localhost where localhost.contains("localhost"):
            if localhost.hasPrefix("http://") {
                environment = .customHttp(localhost.replacingOccurrences(of: "http://", with: ""))
            } else {
                environment = .custom(localhost.replacingOccurrences(of: "https://", with: ""))
            }
        default:
            Log.error("Failed to load environment setting: \(host). Defaulting to \(environment.doh.getCurrentlyUsedHostUrl())",
                      domain: .application)
        }
        #endif
        
        self.userApiConfig = PDClient.APIService.Configuration(environment: environment, clientVersion: clientVersion)

        if let linkHost = Bundle.main.infoDictionary?[SettingsBundleKeys.shareLinkHost.rawValue] as? String,
           !linkHost.isEmpty {
            shareLinkHost = (scheme: "https", host: linkHost)
        } else {
            #if HAS_QA_FEATURES
            shareLinkHost = (scheme: "https", host: host)
            #endif
        }
    }
    
    private(set) static var userApiConfig: PDClient.APIService.Configuration!
    private static var shareLinkHost = (scheme: "", host: "")

    private static var dynamicDomain: String? {
        if let domain = ProcessInfo.processInfo.environment["DYNAMIC_DOMAIN"],
            !domain.isEmpty, URL(string: "https://\(domain)") != nil {
            return domain
        } else {
            return nil
        }
    }
}
